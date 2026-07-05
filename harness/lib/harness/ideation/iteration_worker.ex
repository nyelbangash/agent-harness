defmodule Harness.Ideation.IterationWorker do
  @moduledoc """
  One ideation iteration = one fresh headless session (spec §5.2). No
  conversation carryover — the tree is the memory. Flow:

  1. check stop conditions (budget, frontier empty, no-progress, gate)
  2. select the frontier node (score × novelty_decay(depth))
  3. compile context: seed VERBATIM + ancestor chain + sibling summaries +
     running journal
  4. work: diverge (branch 2–4 children) or develop (deepen + research),
     alternating by depth parity
  5. persist children/artifact + a 3-line journal entry
  6. every `critique_every` iterations, run the Opus critique; else enqueue
     the next iteration

  Concurrency 1 on the :ideate queue means one iteration at a time per node;
  unique per session prevents overlap.
  """

  use Oban.Worker,
    queue: :ideate,
    max_attempts: 3,
    unique: [keys: [:session_id], states: :incomplete, period: :infinity]

  require Logger

  alias Harness.Ideation
  alias Harness.Runs.RunSpec
  alias Harness.{Policy, Runs}

  @ideate_tools ~w(WebSearch WebFetch Read)

  @diverge_schema Jason.encode!(%{
                    type: "object",
                    properties: %{
                      children: %{
                        type: "array",
                        minItems: 2,
                        maxItems: 4,
                        items: %{
                          type: "object",
                          properties: %{
                            title: %{type: "string"},
                            summary: %{type: "string"},
                            score: %{type: "number", minimum: 0, maximum: 10},
                            artifact: %{type: "string"}
                          },
                          required: ~w(title summary score artifact)
                        }
                      },
                      journal: %{type: "array", items: %{type: "string"}, maxItems: 3}
                    },
                    required: ~w(children journal),
                    additionalProperties: false
                  })

  @develop_schema Jason.encode!(%{
                    type: "object",
                    properties: %{
                      title: %{type: "string"},
                      summary: %{type: "string"},
                      score: %{type: "number", minimum: 0, maximum: 10},
                      artifact: %{type: "string"},
                      journal: %{type: "array", items: %{type: "string"}, maxItems: 3}
                    },
                    required: ~w(title summary score artifact journal),
                    additionalProperties: false
                  })

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"session_id" => session_id}}) do
    session = Ideation.get_session!(session_id)

    cond do
      session.status != "running" ->
        {:cancel, :session_not_running}

      reason = stop_reason(session) ->
        finish(session, reason)

      true ->
        case Policy.gate(:ideate) do
          :ok ->
            iterate(session)

          # utilization/window defers are TRANSIENT — snooze and retry, never
          # kill a multi-hour session (which would also burn a premature
          # synthesis). The budget check above is the real terminator.
          {:snooze, seconds, _} ->
            {:snooze, seconds}

          {:skip, _reason} ->
            {:snooze, Policy.get().utilization_gates.poll_minutes * 60}
        end
    end
  end

  defp stop_reason(session) do
    cond do
      budget_exhausted?(session) -> :budget_exhausted
      # spec §5.2: two CONSECUTIVE CRITIQUES (not iterations) reporting no
      # material progress — tracked in its own counter
      session.critique_no_progress_streak >= 2 -> :no_material_progress
      Ideation.frontier_count(session.id) == 0 and session.iterations > 0 -> :frontier_empty
      true -> nil
    end
  end

  defp budget_exhausted?(session) do
    DateTime.diff(DateTime.utc_now(), session.started_at, :second) >= session.budget_minutes * 60
  end

  defp iterate(session) do
    grounding = Ideation.grounding_repos(session)

    case Ideation.select_frontier(session.id) do
      nil ->
        finish(session, :frontier_empty)

      node ->
        # develop on odd depth, diverge on even — alternate breadth and depth
        mode = if rem(node.depth, 2) == 0, do: :diverge, else: :develop
        prompt = Harness.Prompts.ideate(mode, session, node, grounding)

        spec = %RunSpec{
          kind: :ideate,
          model: Policy.get().models.ideate,
          prompt: prompt,
          cwd: Ideation.session_dir(session),
          output_mode: :json,
          json_schema: if(mode == :diverge, do: @diverge_schema, else: @develop_schema),
          allowed_tools: @ideate_tools,
          max_turns: Policy.get().budgets.ideate_iteration_max_turns,
          ref: "ideation-#{session.id}",
          timeout_ms: :timer.minutes(15)
        }

        case Runs.execute(spec) do
          {:ok, result} -> apply_result(session, node, mode, result)
          {:error, :killed} -> {:cancel, :killed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp apply_result(session, node, :diverge, %{structured_output: %{"children" => children} = out}) do
    Ideation.mark_expanded!(node)

    for child <- children do
      Ideation.add_child!(
        session,
        node,
        %{
          title: child["title"],
          summary: child["summary"],
          score: clamp_score(child["score"]),
          model_used: session_model()
        },
        child["artifact"] || ""
      )
    end

    advance(session, out["journal"], length(children) > 0)
  end

  defp apply_result(session, node, :develop, %{structured_output: %{"artifact" => _} = out}) do
    Ideation.add_child!(
      session,
      node,
      %{
        title: out["title"],
        summary: out["summary"],
        score: clamp_score(out["score"]),
        model_used: session_model()
      },
      out["artifact"]
    )

    Ideation.mark_expanded!(node)
    advance(session, out["journal"], true)
  end

  # malformed structured output — count as a no-progress iteration, don't crash
  defp apply_result(session, _node, _mode, _result) do
    Logger.warning("ideation #{session.id}: iteration produced no usable output")
    advance(session, ["iteration produced no usable structured output"], false)
  end

  defp advance(session, journal, progress?) do
    iteration = session.iterations + 1
    Ideation.append_journal!(session, iteration, journal || [])

    # informational only — the stop condition is critique-driven (§5.2), so a
    # transient malformed-JSON iteration no longer counts toward termination
    streak = if progress?, do: 0, else: session.no_progress_streak + 1

    session =
      Ideation.update_session!(session, %{iterations: iteration, no_progress_streak: streak})

    critique_every = Policy.get().ideate.critique_every

    if rem(iteration, critique_every) == 0 do
      %{session_id: session.id}
      |> Harness.Ideation.CritiqueWorker.new()
      |> Oban.insert()
    else
      Ideation.enqueue_iteration(session)
    end

    :ok
  end

  # stop_session! records the reason and enqueues the final synthesis
  defp finish(session, reason) do
    Ideation.stop_session!(session, reason)
    :ok
  end

  defp clamp_score(score) when is_number(score),
    do: score |> max(0.0) |> min(10.0) |> :erlang.float()

  defp clamp_score(_), do: 5.0

  defp session_model, do: Policy.get().models.ideate
end
