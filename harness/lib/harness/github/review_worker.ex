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

  @conflict_resolution_tools ~w(Bash Read Glob Grep Write Edit WebSearch WebFetch)

  @review_tools ~w(Bash Read Glob Grep Write Edit WebSearch WebFetch)

  @implement_tools ~w(Bash Read Glob Grep Write Edit WebSearch WebFetch)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "issue_id" => issue_id,
            "pr_number" => pr_number,
            "round" => round,
            "branch" => branch
          } =
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

    case ensure_mergeable(issue, pr_number, branch, policy) do
      {:error, :escalated} ->
        :ok

      _ ->
        do_review(issue, pr_number, round, branch, policy)
    end
  end

  defp do_review(issue, pr_number, round, branch, policy) do
    worktree_name = "review-issue-#{issue.number}-#{System.unique_integer([:positive])}"
    worktree = Repos.create_worktree_at!(issue.repo, worktree_name, "origin/#{branch}")

    try do
      comments =
        case Client.list_issue_comments(issue.repo, issue.number) do
          {:ok, comments} ->
            Enum.reject(comments, &Provenance.harness_authored?(&1["body"] || ""))

          {:error, _} ->
            []
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

          actionable =
            Enum.filter(all_findings, &(&1["confidence"] >= policy.review.confidence_floor))

          publish_review(
            issue,
            pr_number,
            round,
            branch,
            worktree,
            all_findings,
            actionable,
            result.run_id,
            policy
          )

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

  defp publish_review(
         issue,
         pr_number,
         round,
         branch,
         worktree,
         all_findings,
         actionable,
         run_id,
         policy
       ) do
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
        Logger.warning(
          "Review fix session failed for #{issue.repo}##{pr_number}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp format_findings_for_fix(findings) do
    Enum.map_join(findings, "\n\n", fn f ->
      "**#{f["severity"]}** at `#{f["file"]}:#{f["line"]}`: #{f["summary"]}\nFix hint: #{f["fix_hint"]}"
    end)
  end

  # -- mergeability / rebase helpers -------------------------------------------

  defp ensure_mergeable(issue, pr_number, branch, policy) do
    unless String.starts_with?(branch, "harness/") do
      :ok
    else
      case Client.get_pull_request(issue.repo, pr_number) do
        {:ok, %{mergeable_state: ms}} when ms in ["conflicting", "dirty"] ->
          do_rebase_with_retry(issue, pr_number, branch, policy, lease_retries: 1)

        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "mergeability check failed for #{issue.repo}##{pr_number}: #{inspect(reason)}"
          )

          :ok
      end
    end
  end

  defp do_rebase_with_retry(issue, pr_number, branch, policy, opts) do
    lease_retries = Keyword.get(opts, :lease_retries, 1)
    Repos.ensure_base!(issue.repo)
    base_branch = Repos.default_branch(issue.repo)
    wt_name = "rebase-#{issue.number}-#{System.unique_integer([:positive])}"
    worktree = Repos.create_worktree_at!(issue.repo, wt_name, "origin/#{branch}")

    result =
      try do
        rebase_loop(
          issue,
          pr_number,
          branch,
          worktree,
          base_branch,
          policy,
          policy.review.rebase_max_attempts
        )
      after
        Repos.remove_worktree!(issue.repo, worktree)
      end

    case result do
      {:error, :lease_broken} when lease_retries > 0 ->
        Logger.info("lease broken for #{issue.repo}##{pr_number}, retrying rebase once")
        do_rebase_with_retry(issue, pr_number, branch, policy, lease_retries: lease_retries - 1)

      other ->
        other
    end
  end

  defp rebase_loop(issue, pr_number, _branch, _worktree, _base_branch, _policy, 0) do
    Logger.warning("rebase_max_attempts exhausted for PR ##{pr_number}")
    escalate_conflict(issue, pr_number, [])
  end

  defp rebase_loop(issue, pr_number, branch, worktree, base_branch, policy, attempts) do
    case Repos.rebase_onto!(issue.repo, worktree, base_branch) do
      :ok ->
        verify_and_push(issue, pr_number, branch, worktree, policy)

      {:conflict, conflicted_files} ->
        case resolve_conflicts(issue, worktree, conflicted_files, base_branch, policy) do
          :ok ->
            case Repos.rebase_continue!(issue.repo, worktree) do
              :ok ->
                verify_and_push(issue, pr_number, branch, worktree, policy)

              {:conflict, _still_conflicted} ->
                Repos.rebase_abort!(issue.repo, worktree)
                rebase_loop(issue, pr_number, branch, worktree, base_branch, policy, attempts - 1)
            end

          {:error, reason} ->
            Logger.warning("conflict resolution session failed: #{inspect(reason)}")
            Repos.rebase_abort!(issue.repo, worktree)
            escalate_conflict(issue, pr_number, conflicted_files)
        end
    end
  end

  defp verify_and_push(issue, pr_number, branch, worktree, policy) do
    repo_cfg = Enum.find(policy.github.repos, &(&1.name == issue.repo))
    verify_result = if repo_cfg, do: Verifier.verify(worktree, repo_cfg), else: :ok

    case verify_result do
      :ok ->
        case Repos.force_push_head!(issue.repo, worktree, branch) do
          :ok ->
            Logger.info("Rebased and pushed #{issue.repo}##{pr_number} successfully")
            :ok

          {:error, :lease_broken} ->
            {:error, :lease_broken}
        end

      {:failed, transcript} ->
        Logger.warning(
          "Rebase verify failed for #{issue.repo}##{pr_number}: " <>
            String.slice(transcript, 0, 300)
        )

        escalate_conflict(issue, pr_number, [], transcript: transcript)
    end
  end

  defp resolve_conflicts(issue, worktree, conflicted_files, base_branch, policy) do
    file_pairs =
      Enum.map(conflicted_files, fn path ->
        content = File.read!(Path.join(worktree, path))
        {path, content}
      end)

    prompt = Harness.Prompts.resolve_conflict(issue, base_branch, file_pairs)

    spec = %RunSpec{
      kind: :review,
      model: policy.review.fix_model,
      prompt: prompt,
      cwd: worktree,
      worktree: worktree,
      output_mode: :stream_json,
      allowed_tools: @conflict_resolution_tools,
      max_turns: 12,
      issue_id: issue.id,
      ref: "#{issue.repo}##{issue.number}",
      timeout_ms: :timer.minutes(20)
    }

    case Runs.execute(spec) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp escalate_conflict(issue, pr_number, conflicted_files, opts \\ []) do
    file_list = Enum.join(conflicted_files, ", ")

    transcript_note =
      case Keyword.get(opts, :transcript) do
        nil ->
          ""

        t ->
          "\n\nVerification output:\n```\n#{String.slice(t, 0, 1_000)}\n```"
      end

    body =
      """
      Conflicts need human attention: #{file_list}

      The automated rebase and conflict-resolution step could not produce a
      passing build. Please resolve the conflicts manually and push.#{transcript_note}
      """
      |> Provenance.stamp("review", "conflict-escalation")

    Client.post_issue_comment(issue.repo, pr_number, body)

    Harness.Notify.notify(
      :conflict_escalated,
      "PR #{issue.repo}##{pr_number} has unresolvable conflicts: #{file_list}"
    )

    {:error, :escalated}
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
