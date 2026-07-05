defmodule Harness.GitHub.TriageWorker do
  @moduledoc """
  Spec §4.2. One short structured-output session per issue; the JSON contract
  is enforced CLI-side (`--json-schema`) and re-validated in Elixir. Contract
  violations get exactly one corrective re-run inside the same job attempt;
  low confidence (< policy.triage.low_confidence_floor) gets one escalation
  re-run on `models.escalation` (Opus). Routing itself is `Triage.route/2` —
  never the model's call.
  """

  use Oban.Worker,
    queue: :triage,
    max_attempts: 2,
    # period :infinity — Oban's default unique period is only 60s, which
    # would let duplicate triage sessions for one issue coexist
    unique: [keys: [:issue_id], states: :incomplete, period: :infinity]

  require Logger

  alias Harness.GitHub
  alias Harness.GitHub.{Client, Triage}
  alias Harness.Runs.RunSpec
  alias Harness.{Policy, Repos, Runs}

  @triage_tools ~w(Bash Read Glob Grep Write Edit WebSearch WebFetch)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id}}) do
    issue = GitHub.get_issue!(issue_id)

    cond do
      # a snoozed/queued job may execute long after enqueue — never spend
      # model time on an issue that closed (or was skipped/done) meanwhile
      issue.state != "open" or issue.pipeline_state in ~w(done skipped) ->
        {:cancel, :issue_no_longer_actionable}

      "human-only" in issue.labels ->
        GitHub.transition!(issue, "skipped")
        :ok

      issue.pipeline_state in ~w(planning implementing) ->
        # already in flight; the janitor re-triages if the issue changed
        :ok

      true ->
        case Policy.gate(:triage) do
          :ok -> triage(issue)
          {:snooze, seconds, _reason} -> {:snooze, seconds}
          {:skip, reason} -> {:cancel, reason}
        end
    end
  end

  defp triage(issue) do
    policy = Policy.get()

    comments =
      case Client.list_issue_comments(issue.repo, issue.number) do
        {:ok, comments} -> comments
        {:error, _} -> []
      end

    base = Repos.ensure_base!(issue.repo)
    repo_map = Repos.repo_map(issue.repo)
    prompt = Harness.Prompts.triage(issue, comments, repo_map)
    issue = GitHub.transition!(issue, "triaging")

    with {:ok, decision, run_id, model, attempt} <-
           run_with_contract_retry(issue, prompt, base, policy) do
      {decision, run_id, model, attempt} =
        maybe_escalate(issue, prompt, base, policy, decision, run_id, model, attempt)

      finalize(issue, policy, decision, run_id, model, attempt)
    else
      {:contract_failure, run_id, errors} ->
        Logger.warning(
          "triage contract failed twice for #{issue.repo}##{issue.number}: #{inspect(errors)}"
        )

        record_and_route(issue, policy, nil, run_id, %{
          final_route: "plan",
          decision_reason: "contract_failure",
          model: policy.models.triage,
          attempt: 2
        })

      {:error, :killed} ->
        # operator hit the kill switch — do NOT let Oban immediately start a
        # fresh session
        GitHub.transition!(issue, "failed")
        {:cancel, :killed}

      {:error, reason} ->
        GitHub.transition!(issue, "incoming")
        {:error, reason}
    end
  end

  # one run + at most one corrective re-run, per the spec's "retry once"
  defp run_with_contract_retry(issue, prompt, base, policy) do
    case run_once(issue, prompt, base, policy, policy.models.triage) do
      {:ok, result} ->
        case Triage.validate(result.structured_output) do
          {:ok, decision} ->
            {:ok, decision, result.run_id, policy.models.triage, 1}

          {:error, errors} ->
            corrective =
              prompt <>
                "\n\nYour previous response violated the output contract " <>
                "(#{Enum.join(errors, "; ")}). Respond again with ONLY the JSON object."

            case run_once(issue, corrective, base, policy, policy.models.triage) do
              {:ok, retry_result} ->
                case Triage.validate(retry_result.structured_output) do
                  {:ok, decision} -> {:ok, decision, retry_result.run_id, policy.models.triage, 2}
                  {:error, retry_errors} -> {:contract_failure, retry_result.run_id, retry_errors}
                end

              {:error, reason} ->
                {:error, reason}
            end
        end

      # the CLI's own schema retry gave up — treat as one contract strike
      {:error, {:run_failed, "error_max_structured_output_retries"}} ->
        case run_once(issue, prompt, base, policy, policy.models.triage) do
          {:ok, result} ->
            case Triage.validate(result.structured_output) do
              {:ok, decision} -> {:ok, decision, result.run_id, policy.models.triage, 2}
              {:error, errors} -> {:contract_failure, result.run_id, errors}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_escalate(issue, prompt, base, policy, decision, run_id, model, attempt) do
    if decision.confidence < policy.triage.low_confidence_floor and
         model != policy.models.escalation and Policy.gate(:triage) == :ok do
      case run_once(issue, prompt, base, policy, policy.models.escalation) do
        {:ok, result} ->
          case Triage.validate(result.structured_output) do
            {:ok, opus_decision} ->
              {opus_decision, result.run_id, policy.models.escalation, attempt + 1}

            {:error, _} ->
              {decision, run_id, model, attempt}
          end

        {:error, _} ->
          {decision, run_id, model, attempt}
      end
    else
      {decision, run_id, model, attempt}
    end
  end

  defp run_once(issue, prompt, base, policy, model) do
    Runs.execute(%RunSpec{
      kind: :triage,
      model: model,
      prompt: prompt,
      cwd: base,
      output_mode: :json,
      json_schema: Triage.schema_json(),
      allowed_tools: @triage_tools,
      max_turns: policy.budgets.triage_max_turns,
      issue_id: issue.id,
      ref: "#{issue.repo}##{issue.number}",
      timeout_ms: :timer.minutes(10)
    })
  end

  defp finalize(issue, policy, decision, run_id, model, attempt) do
    ctx = %{
      labels: issue.labels,
      auto_threshold: policy.triage.auto_threshold,
      test_command?: test_command?(policy, issue.repo),
      full_auto_active?: Policy.full_auto_active?()
    }

    {final_route, reason} = Triage.route(decision, ctx)

    record_and_route(issue, policy, decision, run_id, %{
      final_route: final_route,
      decision_reason: reason,
      model: model,
      attempt: attempt
    })
  end

  defp record_and_route(issue, _policy, decision, run_id, outcome) do
    GitHub.record_triage!(
      %{
        issue_id: issue.id,
        run_id: run_id,
        proposed_route: decision && decision.route,
        confidence: decision && decision.confidence,
        reasoning: decision && decision.reasoning,
        estimated_scope: decision && decision.estimated_scope,
        risk_flags: (decision && decision.risk_flags) || []
      }
      |> Map.merge(outcome)
    )

    case outcome.final_route do
      "skip" ->
        GitHub.transition!(issue, "skipped")
        :ok

      "auto" ->
        GitHub.transition!(issue, "triaged")

        %{issue_id: issue.id}
        |> Harness.GitHub.ImplementWorker.new()
        |> Oban.insert()

        :ok

      "plan" ->
        GitHub.transition!(issue, "triaged")

        %{issue_id: issue.id}
        |> Harness.GitHub.PlanWorker.new()
        |> Oban.insert()

        :ok
    end
  end

  defp test_command?(policy, repo_name) do
    case Enum.find(policy.github.repos, &(&1.name == repo_name)) do
      %{test_command: cmd} when is_binary(cmd) and cmd != "" -> true
      _ -> false
    end
  end
end
