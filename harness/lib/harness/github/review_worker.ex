defmodule Harness.GitHub.ReviewWorker do
  @moduledoc """
  Adversarial review pass on every harness-authored PR (spec §4.3 extension).

  Triggered by ImplementWorker after a PR is opened. Runs a read-only reviewer
  session against the PR diff, posts a structured GitHub PR review, and can
  drive at most one bounded fix-and-re-review cycle before stopping.

  Job args: issue_id, pr_number, round (0 = initial review), branch.
  """

  use Oban.Worker,
    queue: :review,
    max_attempts: 2,
    unique: [keys: [:issue_id, :pr_number, :round], states: :incomplete, period: :infinity]

  require Logger

  alias Harness.GitHub
  alias Harness.GitHub.{Client, Provenance}
  alias Harness.Runs.RunSpec
  alias Harness.{Policy, Repos, Runs, Verifier}

  @review_tools ~w(Read Glob Grep) ++
                  [
                    "Bash(git log *)",
                    "Bash(git diff *)",
                    "Bash(git show *)",
                    "Bash(git ls-files *)",
                    "Bash(grep *)",
                    "Bash(rg *)",
                    "Bash(ls *)"
                  ]

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
  def perform(%Oban.Job{
        args:
          %{"issue_id" => issue_id, "pr_number" => pr_number, "round" => round, "branch" => branch} =
            _args
      }) do
    issue = GitHub.get_issue!(issue_id)
    policy = Policy.get()

    cond do
      issue.state != "open" or issue.pipeline_state not in ~w(pr_open) ->
        {:cancel, :issue_no_longer_actionable}

      round > policy.review.max_rounds ->
        {:cancel, :round_exceeds_max}

      true ->
        case Policy.gate(:review) do
          :ok -> review_pr(issue, pr_number, round, branch, policy)
          {:snooze, seconds, _reason} -> {:snooze, seconds}
          {:skip, reason} -> {:cancel, reason}
        end
    end
  end

  defp review_pr(issue, pr_number, round, branch, policy) do
    Repos.ensure_base!(issue.repo)

    worktree_name = "review-issue-#{issue.number}-#{System.unique_integer([:positive])}"
    worktree = Repos.create_worktree_at!(issue.repo, worktree_name, "origin/#{branch}")

    try do
      comments =
        case Client.list_issue_comments(issue.repo, issue.number) do
          {:ok, comments} -> Enum.reject(comments, &Provenance.harness_authored?(&1["body"] || ""))
          {:error, _} -> []
        end

      base_branch = Repos.default_branch(issue.repo)
      prompt = Harness.Prompts.review(issue, comments, base_branch)

      spec = %RunSpec{
        kind: :review,
        model: policy.review.model,
        prompt: prompt,
        cwd: worktree,
        worktree: worktree,
        output_mode: :json,
        json_schema: review_schema_json(),
        allowed_tools: @review_tools,
        max_turns: policy.budgets.review_max_turns,
        issue_id: issue.id,
        ref: "#{issue.repo}##{issue.number}",
        timeout_ms: :timer.minutes(30)
      }

      case Runs.execute(spec) do
        {:ok, result} ->
          all_findings = parse_findings(result.structured_output)
          actionable = Enum.filter(all_findings, &(&1["confidence"] >= policy.review.confidence_floor))

          publish_review(issue, pr_number, round, branch, worktree, all_findings, actionable, result.run_id, policy)

        {:error, :killed} ->
          {:cancel, :killed}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Repos.remove_worktree!(issue.repo, worktree)
    end
  end

  defp parse_findings(%{"findings" => findings}) when is_list(findings), do: findings
  defp parse_findings(_), do: []

  defp publish_review(issue, pr_number, round, branch, worktree, all_findings, actionable, run_id, policy) do
    {event, body} =
      if all_findings == [] do
        approval =
          "Adversarial review found no defects. Verification gate passed. PR looks correct."

        {"APPROVE", Provenance.stamp(approval, "review", run_id)}
      else
        bullet_list =
          Enum.map_join(all_findings, "\n", fn f ->
            "- **#{f["severity"]}** `#{f["file"]}:#{f["line"]}` (confidence #{f["confidence"]}): #{f["summary"]}\n  _#{f["fix_hint"]}_"
          end)

        body =
          """
          Adversarial review found #{length(all_findings)} finding(s):

          #{bullet_list}
          """

        {"REQUEST_CHANGES", Provenance.stamp(body, "review", run_id)}
      end

    case Client.create_pull_request_review(issue.repo, pr_number, event, body) do
      {:ok, _} ->
        Logger.info("Posted #{event} review for #{issue.repo}##{pr_number} (round #{round})")

      {:error, reason} ->
        Logger.warning("Failed to post review for #{issue.repo}##{pr_number}: #{inspect(reason)}")
    end

    if actionable != [] and round < policy.review.max_rounds do
      fix_cycle(issue, pr_number, round, branch, worktree, actionable, policy)
    else
      :ok
    end
  end

  defp fix_cycle(issue, pr_number, round, branch, worktree, actionable, policy) do
    repo_cfg = Enum.find(policy.github.repos, &(&1.name == issue.repo))

    fix_prompt = """
    The automated adversarial review found the following issues with the PR you wrote.
    Fix each issue below. Do not weaken or delete tests to make them pass — fix the code.

    #{format_findings_for_fix(actionable)}
    """

    fix_spec = %RunSpec{
      kind: :review,
      model: policy.review.fix_model,
      prompt: fix_prompt,
      cwd: worktree,
      worktree: worktree,
      output_mode: :stream_json,
      allowed_tools: @implement_tools,
      max_turns: policy.budgets.review_max_turns,
      issue_id: issue.id,
      ref: "#{issue.repo}##{issue.number}",
      timeout_ms: :timer.minutes(45)
    }

    case Runs.execute(fix_spec) do
      {:ok, _result} ->
        verify_result =
          if repo_cfg do
            Verifier.verify(worktree, repo_cfg)
          else
            :ok
          end

        case verify_result do
          :ok ->
            Repos.publish_branch!(
              issue.repo,
              worktree,
              branch,
              :all,
              "Review fixes for ##{pr_number} (round #{round})"
            )

            %{issue_id: issue.id, pr_number: pr_number, round: round + 1, branch: branch}
            |> Harness.GitHub.ReviewWorker.new()
            |> Oban.insert()

            :ok

          {:failed, transcript} ->
            Logger.warning(
              "Review fix cycle for #{issue.repo}##{pr_number} stayed red — leaving REQUEST_CHANGES in place.\n#{String.slice(transcript, 0, 500)}"
            )

            :ok
        end

      {:error, :killed} ->
        {:cancel, :killed}

      {:error, reason} ->
        Logger.warning("Review fix session failed for #{issue.repo}##{pr_number}: #{inspect(reason)}")
        :ok
    end
  end

  defp format_findings_for_fix(findings) do
    Enum.map_join(findings, "\n\n", fn f ->
      "**#{f["severity"]}** at `#{f["file"]}:#{f["line"]}`: #{f["summary"]}\nFix hint: #{f["fix_hint"]}"
    end)
  end

  defp review_schema_json do
    Jason.encode!(%{
      type: "object",
      properties: %{
        findings: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              file: %{type: "string"},
              line: %{type: "integer"},
              severity: %{type: "string", enum: ["error", "warning", "info"]},
              summary: %{type: "string"},
              fix_hint: %{type: "string"},
              confidence: %{type: "number", minimum: 0, maximum: 1}
            },
            required: ~w(file line severity summary fix_hint confidence),
            additionalProperties: false
          }
        }
      },
      required: ["findings"],
      additionalProperties: false
    })
  end
end
