defmodule Harness.GitHub.RespondWorker do
  @moduledoc """
  Responds to operator review comments on harness/* PRs.

  Triggered by PollWorker when it finds a non-harness-stamped comment on a
  PR belonging to an issue in `@respondable_states` — not just the PAT
  owner's comments, any collaborator's. Runs two phases:

  1. Pre-flight (structured output): decides `fix` or `decline_with_reason`
     using read-only tools; if out of scope, posts a stamped decline reply.
  2. Fix session: runs the implement tool-set in the PR branch worktree,
     runs the verify gate (hard), pushes a new commit, posts a stamped reply.

  Never force-pushes. Respects the pause gate. The fix session is bounded by
  its wall-clock timeout, not a turn cap.
  """

  use Oban.Worker,
    queue: :respond,
    max_attempts: 2,
    unique: [keys: [:pr_comment_handle_id], states: :incomplete, period: :infinity]

  require Logger

  alias Harness.GitHub
  alias Harness.GitHub.{Client, Issue, PrCommentHandle, Provenance}
  alias Harness.Runs.RunSpec
  alias Harness.{Policy, Repos, Runs, Verifier}

  @read_only_tools ~w(Bash Read Glob Grep Write Edit WebSearch WebFetch)

  @implement_tools ~w(Bash Read Glob Grep Write Edit WebSearch WebFetch)

  # Pipeline states with a standing PR that a scoped continuation can push a
  # fix commit to. Kept in sync with `PollWorker.@respondable`.
  @respondable_states ~w(pr_open review_stalled plan_ready failed done)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "pr_comment_handle_id" => handle_id,
            "issue_id" => issue_id
          } = args
      }) do
    handle = Harness.Repo.get!(PrCommentHandle, handle_id)
    issue = GitHub.get_issue!(issue_id)

    cond do
      issue.pipeline_state not in @respondable_states or is_nil(issue.pr_number) ->
        {:cancel, :issue_no_longer_actionable}

      true ->
        case Policy.gate(:plan) do
          :ok -> respond(handle, issue, args)
          {:snooze, seconds, _reason} -> {:snooze, seconds}
          {:skip, reason} -> {:cancel, reason}
        end
    end
  end

  defp respond(handle, issue, args) do
    policy = Policy.get()
    repo_cfg = Enum.find(policy.github.repos, &(&1.name == issue.repo))

    if repo_cfg == nil do
      {:cancel, :repo_not_in_policy}
    else
      branch = Issue.branch_name(issue)
      run_in_worktree(handle, issue, policy, repo_cfg, branch, args)
    end
  end

  defp run_in_worktree(handle, issue, policy, repo_cfg, branch, args) do
    Repos.ensure_base!(issue.repo)

    worktree =
      Repos.create_worktree_at!(
        issue.repo,
        "respond-#{handle.id}-#{System.unique_integer([:positive])}",
        "origin/#{branch}"
      )

    try do
      do_respond(handle, issue, policy, repo_cfg, branch, worktree, args)
    after
      Repos.remove_worktree!(issue.repo, worktree)
    end
  end

  defp do_respond(handle, issue, policy, repo_cfg, branch, worktree, args) do
    comment_body = args["comment_body"] || ""
    comment_path = args["comment_path"]
    comment_line = args["comment_line"]
    comment_diff_hunk = args["comment_diff_hunk"]

    comments =
      case Client.list_issue_comments(issue.repo, issue.number) do
        {:ok, c} -> c
        {:error, _} -> []
      end

    plan = GitHub.ready_plan(issue.id)
    plan_text = plan && File.read!(plan.plan_path)

    prompt =
      pre_flight_prompt(
        issue,
        branch,
        comment_body,
        comment_path,
        comment_line,
        comment_diff_hunk,
        comments,
        plan_text
      )

    spec = %RunSpec{
      kind: :respond,
      model: policy.models.respond,
      prompt: prompt,
      cwd: worktree,
      worktree: worktree,
      output_mode: :json,
      json_schema: respond_schema(),
      allowed_tools: @read_only_tools,
      issue_id: issue.id,
      ref: "#{issue.repo}##{issue.number}",
      timeout_ms: :timer.minutes(10)
    }

    case Runs.execute(spec) do
      {:ok, pre_flight} ->
        action = get_in(pre_flight.structured_output || %{}, ["action"])
        reason = get_in(pre_flight.structured_output || %{}, ["reason"]) || ""

        case action do
          "decline_with_reason" ->
            body =
              Provenance.stamp(
                "I reviewed this comment but it is outside the scope of this branch.\n\n#{reason}",
                "respond",
                pre_flight.run_id
              )

            post_reply(handle, issue, body)

            GitHub.update_pr_comment_handle!(handle, %{
              action: "decline_with_reason",
              run_id: pre_flight.run_id
            })

            :ok

          "fix" ->
            run_fix_phase(
              handle,
              issue,
              policy,
              repo_cfg,
              branch,
              worktree,
              comment_body,
              pre_flight
            )

          _ ->
            Logger.warning(
              "RespondWorker unexpected action #{inspect(action)} for handle #{handle.id}"
            )

            body =
              Provenance.stamp(
                "Unable to determine the appropriate action for this comment.",
                "respond",
                pre_flight.run_id
              )

            post_reply(handle, issue, body)

            GitHub.update_pr_comment_handle!(handle, %{
              action: "decline_with_reason",
              run_id: pre_flight.run_id
            })

            :ok
        end

      {:error, :killed} ->
        {:cancel, :killed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_fix_phase(handle, issue, policy, repo_cfg, branch, worktree, comment_body, pre_flight) do
    fix_prompt = """
    The pre-flight check confirmed this change is in scope. Make the targeted fix.

    Original comment: #{comment_body}
    """

    spec = %RunSpec{
      kind: :respond,
      model: policy.models.respond,
      prompt: fix_prompt,
      cwd: worktree,
      worktree: worktree,
      output_mode: :stream_json,
      allowed_tools: @implement_tools,
      issue_id: issue.id,
      ref: "#{issue.repo}##{issue.number}",
      timeout_ms: :timer.minutes(45)
    }

    case Runs.execute(spec) do
      {:ok, fix_result} ->
        case Verifier.verify(worktree, repo_cfg) do
          :ok ->
            short = String.slice(comment_body, 0, 72)
            Repos.push_commit!(issue.repo, worktree, branch, "Respond to review: #{short}")

            body =
              Provenance.stamp(
                "Pushed a fix in response to this comment. Changes committed to `#{branch}`.",
                "respond",
                fix_result.run_id
              )

            post_reply(handle, issue, body)
            GitHub.update_pr_comment_handle!(handle, %{action: "fix", run_id: fix_result.run_id})
            :ok

          {:failed, transcript} ->
            Logger.warning("RespondWorker verify failed for handle #{handle.id}")

            body =
              Provenance.stamp(
                "I attempted a fix for this comment but verification failed — the change was not pushed.\n\n" <>
                  "```\n#{String.slice(transcript, 0, 2_000)}\n```",
                "respond",
                fix_result.run_id
              )

            post_reply(handle, issue, body)

            GitHub.update_pr_comment_handle!(handle, %{
              action: "decline_with_reason",
              run_id: fix_result.run_id
            })

            :ok
        end

      {:error, :killed} ->
        {:cancel, :killed}

      {:error, reason} ->
        # Pre-flight already ran; keep its run_id in the handle as partial record
        GitHub.update_pr_comment_handle!(handle, %{
          action: "decline_with_reason",
          run_id: pre_flight.run_id
        })

        {:error, reason}
    end
  end

  defp post_reply(handle, issue, body) do
    case handle.comment_type do
      "review" ->
        Client.post_pr_review_comment_reply(
          issue.repo,
          issue.pr_number,
          handle.comment_id,
          body
        )

      "issue" ->
        case Client.post_issue_comment(issue.repo, issue.pr_number, body) do
          {:ok, comment_id, created_at} ->
            GitHub.acknowledge_comment_timestamp!(issue, comment_id, created_at)

          _ ->
            :ok
        end
    end
  end

  defp pre_flight_prompt(
         issue,
         branch,
         comment_body,
         comment_path,
         comment_line,
         comment_diff_hunk,
         comments,
         plan_text
       ) do
    location =
      if comment_path do
        line_note = if comment_line, do: ", line #{comment_line}", else: ""
        "File: `#{comment_path}`#{line_note}\n"
      else
        ""
      end

    hunk =
      if comment_diff_hunk do
        "```diff\n#{comment_diff_hunk}\n```\n\n"
      else
        ""
      end

    plan_section =
      if plan_text do
        "## Plan\n\n#{plan_text}\n\n"
      else
        ""
      end

    comment_thread =
      if comments != [] do
        formatted =
          Enum.map_join(comments, "\n---\n", fn c ->
            "**#{c["user"]["login"]}**: #{c["body"]}"
          end)

        "## Issue comments\n\n#{formatted}\n\n"
      else
        ""
      end

    """
    You are reviewing a PR comment to decide whether to attempt a code fix.

    ## Source issue
    ##{issue.number}: #{issue.title}

    #{issue.body || ""}

    ## PR branch
    `#{branch}`

    #{plan_section}## PR comment
    #{location}#{hunk}> #{comment_body}

    #{comment_thread}## Decision
    Read the code in this worktree, then return JSON:
    - `action`: `"fix"` if you can make a targeted, safe change on this branch to address the comment; `"decline_with_reason"` if the request is out of scope, ambiguous, or unsafe.
    - `reason`: always explain your decision.
    """
  end

  defp respond_schema do
    Jason.encode!(%{
      type: "object",
      properties: %{
        action: %{type: "string", enum: ["fix", "decline_with_reason"]},
        reason: %{type: "string"}
      },
      required: ["action", "reason"],
      additionalProperties: false
    })
  end
end
