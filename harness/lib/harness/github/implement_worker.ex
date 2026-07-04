defmodule Harness.GitHub.ImplementWorker do
  @moduledoc """
  The auto lane (spec §4.3). One issue per job, in its own worktree:

  1. implement session (agent writes code; never commits, never pushes)
  2. HARD verification gate in Elixir — the repo's configured test/lint/
     typecheck commands via `Harness.Verifier`; the agent's word counts for
     nothing
  3. failures loop back to the agent with the failure transcript, up to
     `policy.implement.max_fix_cycles`; still red → demote to the plan lane
     with the transcript attached
  4. green → HOST commits + pushes `harness/issue-{n}-{slug}`, opens the PR,
     comments on the issue. The agent never merges; §9.2 guard prevents
     default-branch pushes.

  Reached two ways: triage routing `auto` (full_auto mode only), or the
  operator's promote-to-auto button (`promoted: true` skips the full-auto
  mode/window gate — a human just decided — but still respects pause).
  """

  use Oban.Worker,
    queue: :implement,
    max_attempts: 2,
    unique: [keys: [:issue_id], states: :incomplete, period: :infinity]

  require Logger

  alias Harness.GitHub
  alias Harness.GitHub.Client
  alias Harness.Runs.RunSpec
  alias Harness.{Policy, Repos, Runs, Verifier}

  @implement_tools ~w(Read Glob Grep Write Edit) ++
                     [
                       "Bash(git status *)",
                       "Bash(git diff *)",
                       "Bash(git log *)",
                       "Bash(git show *)",
                       "Bash(git ls-files *)",
                       "Bash(ls *)",
                       "Bash(grep *)",
                       "Bash(rg *)",
                       "Bash(cat *)",
                       "Bash(mix *)",
                       "Bash(npm *)",
                       "Bash(npx *)",
                       "Bash(node *)",
                       "Bash(python *)",
                       "Bash(pytest *)",
                       "Bash(cargo *)",
                       "Bash(go *)"
                     ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id} = args}) do
    issue = GitHub.get_issue!(issue_id)
    promoted? = args["promoted"] == true

    cond do
      issue.state != "open" or issue.pipeline_state in ~w(done skipped pr_open) ->
        {:cancel, :issue_no_longer_actionable}

      true ->
        case gate(promoted?) do
          :ok -> implement(issue, promoted?)
          {:snooze, seconds, _reason} -> {:snooze, seconds}
          {:skip, reason} -> {:cancel, reason}
        end
    end
  end

  # promotion is an explicit human decision — bypass the full-auto
  # mode/window gate but never the pause/usage brakes (gate(:plan) checks
  # exactly those)
  defp gate(true), do: Policy.gate(:plan)
  defp gate(false), do: Policy.gate(:implement)

  defp implement(issue, promoted?) do
    policy = Policy.get()
    repo_cfg = Enum.find(policy.github.repos, &(&1.name == issue.repo))

    cond do
      repo_cfg == nil ->
        {:cancel, :repo_not_in_policy}

      repo_cfg.test_command in [nil, ""] ->
        # without a verification command the gate can't gate — plan instead
        Logger.warning("#{issue.repo} has no test_command; demoting ##{issue.number} to plan")
        demote_to_plan(issue, nil)

      true ->
        run_in_worktree(issue, policy, repo_cfg, promoted?)
    end
  end

  defp run_in_worktree(issue, policy, repo_cfg, promoted?) do
    Repos.ensure_base!(issue.repo)

    worktree =
      Repos.create_worktree!(
        issue.repo,
        "impl-issue-#{issue.number}-#{System.unique_integer([:positive])}"
      )

    try do
      comments =
        case Client.list_issue_comments(issue.repo, issue.number) do
          {:ok, comments} -> comments
          {:error, _} -> []
        end

      plan = GitHub.ready_plan(issue.id)
      plan_text = plan && File.read!(plan.plan_path)
      prompt = Harness.Prompts.implement(issue, comments, plan_text, repo_cfg)
      issue = GitHub.transition!(issue, "implementing")

      case fix_cycle_loop(issue, policy, repo_cfg, worktree, prompt, 0, nil) do
        {:green, run_id} ->
          publish(issue, worktree, run_id, promoted?)

        {:red, transcript, _run_id} ->
          Logger.warning(
            "auto lane for #{issue.repo}##{issue.number} stayed red after " <>
              "#{policy.implement.max_fix_cycles} fix cycles — demoting to plan"
          )

          demote_to_plan(issue, transcript)

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

  # cycle 0 = the initial implement session; each further cycle feeds the
  # verification transcript back
  defp fix_cycle_loop(issue, policy, repo_cfg, worktree, prompt, cycle, _last_transcript) do
    spec = %RunSpec{
      kind: :implement,
      model: policy.models.implement,
      prompt: prompt,
      cwd: worktree,
      worktree: worktree,
      output_mode: :stream_json,
      allowed_tools: @implement_tools,
      max_turns: policy.budgets.implement_max_turns,
      issue_id: issue.id,
      ref: "#{issue.repo}##{issue.number}",
      timeout_ms: :timer.minutes(45)
    }

    case Runs.execute(spec) do
      {:ok, result} ->
        case Verifier.verify(worktree, repo_cfg) do
          :ok ->
            {:green, result.run_id}

          {:failed, transcript} ->
            if cycle < policy.implement.max_fix_cycles do
              fix_prompt = """
              The verification gate rejected your changes in this worktree.
              Fix the failures below, keeping the original issue's intent. Do not
              weaken or delete tests to make them pass — fix the code.

              #{transcript}
              """

              fix_cycle_loop(issue, policy, repo_cfg, worktree, fix_prompt, cycle + 1, transcript)
            else
              {:red, transcript, result.run_id}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish(issue, worktree, run_id, promoted?) do
    branch = "harness/issue-#{issue.number}-#{slug(issue.title)}"

    Repos.publish_branch!(
      issue.repo,
      worktree,
      branch,
      :all,
      "Fix ##{issue.number}: #{issue.title}"
    )

    [owner, _name] = String.split(issue.repo, "/")
    base = Repos.default_branch(issue.repo)
    body = pr_body(issue, run_id)

    case Client.create_pull_request(issue.repo, "#{owner}:#{branch}", base, pr_title(issue), body) do
      {:ok, %{number: pr_number, url: pr_url}} ->
        Client.post_issue_comment(
          issue.repo,
          issue.number,
          "Opened #{pr_url} for this issue (harness auto lane; verification green)."
        )

        issue
        |> Harness.GitHub.Issue.changeset(%{pr_url: pr_url, pr_number: pr_number})
        |> Harness.Repo.update!()
        |> GitHub.transition!("pr_open")

        if promoted?, do: mark_plan_promoted(issue.id)
        :ok

      {:error, reason} ->
        Logger.error("PR creation failed for #{issue.repo}##{issue.number}: #{inspect(reason)}")
        GitHub.transition!(issue, "failed")
        {:error, {:pr_creation_failed, reason}}
    end
  end

  defp demote_to_plan(issue, transcript) do
    GitHub.transition!(issue, "triaged")

    args =
      if transcript do
        %{issue_id: issue.id, failure_transcript: String.slice(transcript, 0, 8_000)}
      else
        %{issue_id: issue.id}
      end

    args |> Harness.GitHub.PlanWorker.new() |> Oban.insert()
    :ok
  end

  defp mark_plan_promoted(issue_id) do
    if plan = GitHub.ready_plan(issue_id) do
      plan |> Harness.GitHub.Plan.changeset(%{status: "promoted"}) |> Harness.Repo.update!()
    end
  end

  defp pr_title(issue), do: "Fix ##{issue.number}: #{issue.title}"

  defp pr_body(issue, run_id) do
    """
    ## Summary

    Automated fix for ##{issue.number} (#{issue.title}), produced by the harness auto lane.

    ## Verification

    The repository's configured test#{if run_id, do: "/lint/typecheck", else: ""} commands ran
    green in the isolated worktree before this branch was pushed (gate enforced by the
    pipeline, not the agent).

    ## Transcript

    Full agent session: http://localhost:4040/runs/#{run_id} (Mission Control, local)

    ---
    _The harness never merges — review required._
    """
  end

  defp slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
  end
end
