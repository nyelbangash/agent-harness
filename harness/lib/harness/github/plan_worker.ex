defmodule Harness.GitHub.PlanWorker do
  @moduledoc """
  Spec §4.4. Runs the planning session in a throwaway worktree, verifies the
  two deliverables exist, copies them to `~/.harness/plans/` (they outlive
  the worktree), and publishes — a `harness/plans/issue-{n}` branch pushed by
  the HOST (the agent never commits or pushes), or an issue comment when
  `policy.plan.post_to_issue`.

  Queue note: `:plan` (concurrency 1), split from `:implement` on 2026-07-05 —
  sharing one slot let a 15-minute implement starve eleven queued plans. One
  plan + one implement may now run concurrently; the SQLite ingest hardening
  (issue #6) made that safe.
  """

  use Oban.Worker,
    queue: :plan,
    max_attempts: 2,
    # period :infinity — the 60s default would allow duplicate plan sessions
    unique: [keys: [:issue_id], states: :incomplete, period: :infinity]

  require Logger

  alias Harness.GitHub
  alias Harness.GitHub.Client
  alias Harness.GitHub.Provenance
  alias Harness.Runs.RunSpec
  alias Harness.{Policy, Repos, Runs}

  @plan_tools ~w(Read Glob Grep Write Edit) ++
                [
                  "Bash(git log *)",
                  "Bash(git show *)",
                  "Bash(git diff *)",
                  "Bash(git blame *)",
                  "Bash(git ls-files *)",
                  "Bash(grep *)",
                  "Bash(rg *)",
                  "Bash(ls *)"
                ]

  @min_artifact_bytes 400

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id} = args}) do
    issue = GitHub.get_issue!(issue_id)

    cond do
      issue.state != "open" or issue.pipeline_state in ~w(done skipped) ->
        {:cancel, :issue_no_longer_actionable}

      true ->
        case Policy.gate(:plan) do
          :ok -> plan(issue, args["failure_transcript"])
          {:snooze, seconds, _reason} -> {:snooze, seconds}
          {:skip, reason} -> {:cancel, reason}
        end
    end
  end

  defp plan(issue, failure_transcript) do
    policy = Policy.get()
    Repos.ensure_base!(issue.repo)

    worktree =
      Repos.create_worktree!(
        issue.repo,
        "plan-issue-#{issue.number}-#{System.unique_integer([:positive])}"
      )

    try do
      comments =
        case Client.list_issue_comments(issue.repo, issue.number) do
          {:ok, comments} -> comments
          {:error, _} -> []
        end

      triage = GitHub.latest_triage(issue.id)
      default_branch = Repos.default_branch(issue.repo)
      prompt = Harness.Prompts.plan(issue, comments, triage, default_branch, policy.budgets.plan_max_turns, failure_transcript)
      issue = GitHub.transition!(issue, "planning")

      spec = %RunSpec{
        kind: :plan,
        model: policy.models.plan,
        prompt: prompt,
        cwd: worktree,
        worktree: worktree,
        output_mode: :stream_json,
        allowed_tools: @plan_tools,
        max_turns: policy.budgets.plan_max_turns,
        issue_id: issue.id,
        ref: "#{issue.repo}##{issue.number}"
      }

      case Runs.execute(spec) do
        {:ok, result} ->
          publish(issue, policy, worktree, result)

        {:error, :killed} ->
          GitHub.transition!(issue, "failed")
          {:cancel, :killed}

        {:error, reason} ->
          GitHub.transition!(issue, "failed")
          {:error, reason}
      end
    after
      Repos.remove_worktree!(issue.repo, worktree)
    end
  end

  defp publish(issue, policy, worktree, result) do
    plan_src = Path.join(worktree, "PLAN.md")
    context_src = Path.join(worktree, "CONTEXT.md")

    if artifact_ok?(plan_src) and artifact_ok?(context_src) do
      dest =
        Path.join([
          Application.fetch_env!(:harness, :harness_home),
          "plans",
          String.replace(issue.repo, "/", "--"),
          "issue-#{issue.number}"
        ])

      File.mkdir_p!(dest)
      plan_path = Path.join(dest, "PLAN.md")
      context_path = Path.join(dest, "CONTEXT.md")
      File.cp!(plan_src, plan_path)
      File.cp!(context_src, context_path)

      # record BEFORE the irreversible external publish — a DB failure after
      # a comment/push would otherwise re-run the whole session on retry and
      # publish a duplicate
      plan =
        GitHub.record_plan!(%{
          issue_id: issue.id,
          run_id: result.run_id,
          plan_path: plan_path,
          context_path: context_path,
          summary: plan_path |> File.read!() |> String.slice(0, 500)
        })

      {branch, comment_id} = deliver(issue, policy, worktree, result.run_id)

      plan
      |> Harness.GitHub.Plan.changeset(%{branch: branch, issue_comment_id: comment_id})
      |> Harness.Repo.update!()

      GitHub.transition!(issue, "plan_ready")

      Harness.Notify.notify(
        :plan_ready,
        "Plan ready for #{issue.repo}##{issue.number}: #{issue.title}"
      )

      :ok
    else
      Logger.warning("plan run for #{issue.repo}##{issue.number} left no usable artifacts")
      GitHub.transition!(issue, "failed")
      {:error, :missing_plan_artifacts}
    end
  end

  defp deliver(issue, policy, worktree, run_id) do
    if policy.plan.post_to_issue do
      raw_body = """
      ## Implementation plan (generated by harness)

      #{File.read!(Path.join(worktree, "PLAN.md"))}

      ---

      #{File.read!(Path.join(worktree, "CONTEXT.md"))}
      """

      body = Provenance.stamp(raw_body, "plan", run_id)

      case Client.post_issue_comment(issue.repo, issue.number, body) do
        {:ok, comment_id} ->
          {nil, comment_id}

        {:error, reason} ->
          Logger.warning("comment publish failed (#{inspect(reason)}), falling back to branch")
          {push_branch(issue, worktree), nil}
      end
    else
      {push_branch(issue, worktree), nil}
    end
  end

  defp push_branch(issue, worktree) do
    branch = "harness/plans/issue-#{issue.number}"

    Repos.publish_branch!(
      issue.repo,
      worktree,
      branch,
      ["PLAN.md", "CONTEXT.md"],
      "Plan packet for ##{issue.number}: #{issue.title}"
    )

    branch
  end

  defp artifact_ok?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size >= @min_artifact_bytes
      _ -> false
    end
  end
end
