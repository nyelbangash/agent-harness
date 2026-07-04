defmodule Harness.Ideation.CritiqueWorker do
  @moduledoc """
  The critique checkpoint (spec §5.2, every `critique_every` iterations) and
  the final synthesis. Uses the Opus critique model to: re-score the frontier,
  prune dead branches (mark, never delete), explicitly answer "is this still
  in service of the seed?" (anti-drift), and — when `final` — write
  SYNTHESIS.md with the 3–5 strongest branches and recommended next actions.
  """

  use Oban.Worker, queue: :ideate, max_attempts: 3

  require Logger

  alias Harness.Ideation
  alias Harness.Runs.RunSpec
  alias Harness.{Policy, Runs}

  @critique_schema Jason.encode!(%{
                     type: "object",
                     properties: %{
                       rescored: %{
                         type: "array",
                         items: %{
                           type: "object",
                           properties: %{
                             idea_id: %{type: "integer"},
                             score: %{type: "number", minimum: 0, maximum: 10},
                             prune: %{type: "boolean"}
                           },
                           required: ~w(idea_id score prune)
                         }
                       },
                       drift: %{type: "boolean"},
                       material_progress: %{type: "boolean"},
                       note: %{type: "string"}
                     },
                     required: ~w(rescored drift material_progress note),
                     additionalProperties: false
                   })

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"session_id" => session_id} = args}) do
    session = Ideation.get_session!(session_id)

    cond do
      # the final synthesis must run even for a stopped/operator-stopped
      # session — it's the wrap-up; only skip it once already synthesized
      args["final"] ->
        if session.status == "synthesized",
          do: {:cancel, :already_synthesized},
          else: synthesize(session)

      # a mid-run critique on a session that stopped/paused while queued must
      # not spend an Opus session
      session.status != "running" ->
        {:cancel, :session_not_running}

      true ->
        case Policy.gate(:ideate) do
          :ok -> critique(session)
          {:snooze, seconds, _} -> {:snooze, seconds}
          {:skip, _} -> {:snooze, Policy.get().utilization_gates.poll_minutes * 60}
        end
    end
  end

  defp critique(session) do
    prompt = Harness.Prompts.critique(session)

    spec = %RunSpec{
      kind: :critique,
      model: Policy.get().models.critique,
      prompt: prompt,
      cwd: Ideation.session_dir(session),
      output_mode: :json,
      json_schema: @critique_schema,
      allowed_tools: ["Read"],
      max_turns: 15,
      ref: "ideation-#{session.id}",
      timeout_ms: :timer.minutes(15)
    }

    case Runs.execute(spec) do
      {:ok, %{structured_output: %{"rescored" => rescored} = out}} ->
        apply_critique(session, rescored, out)

      {:error, :killed} ->
        {:cancel, :killed}

      _ ->
        Logger.warning("ideation #{session.id}: critique produced no usable output")
        Ideation.enqueue_iteration(session)
        :ok
    end
  end

  defp apply_critique(session, rescored, out) do
    for %{"idea_id" => id} = entry <- rescored do
      case Harness.Repo.get(Harness.Ideation.Idea, id) do
        nil ->
          :ok

        idea ->
          Ideation.set_score!(idea, clamp(entry["score"]))
          if entry["prune"] == true and idea.status == "frontier", do: Ideation.mark_pruned!(idea)
      end
    end

    Ideation.append_journal!(session, session.iterations, [
      "CRITIQUE: #{String.slice(out["note"] || "", 0, 180)}",
      "drift=#{out["drift"]} · material_progress=#{out["material_progress"]}"
    ])

    # §5.2: two consecutive CRITIQUES with no material progress stop the run
    critique_streak =
      if out["material_progress"] == false,
        do: session.critique_no_progress_streak + 1,
        else: 0

    session =
      Ideation.update_session!(session, %{
        critiques: session.critiques + 1,
        critique_no_progress_streak: critique_streak
      })

    # the next IterationWorker re-checks stop conditions (incl. the streak)
    Ideation.enqueue_iteration(session)
    :ok
  end

  defp synthesize(session) do
    prompt = Harness.Prompts.synthesis(session)

    spec = %RunSpec{
      kind: :critique,
      model: Policy.get().models.critique,
      prompt: prompt,
      cwd: Ideation.session_dir(session),
      output_mode: :stream_json,
      allowed_tools: ["Read", "Write"],
      max_turns: 20,
      ref: "ideation-#{session.id}",
      timeout_ms: :timer.minutes(15)
    }

    case Runs.execute(spec) do
      {:ok, _result} ->
        path = Ideation.synthesis_path(session)

        if File.exists?(path) do
          Ideation.update_session!(session, %{status: "synthesized", synthesis_path: path})
        else
          Logger.warning("ideation #{session.id}: synthesis wrote no SYNTHESIS.md")
        end

        :ok

      {:error, :killed} ->
        {:cancel, :killed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clamp(score) when is_number(score), do: score |> max(0.0) |> min(10.0) |> :erlang.float()
  defp clamp(_), do: 5.0
end
