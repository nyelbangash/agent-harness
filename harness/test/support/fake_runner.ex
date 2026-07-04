defmodule Harness.Runs.FakeRunner do
  @moduledoc """
  Scriptable `Harness.Runs.Runner` for worker tests. Configure per-test:

      FakeRunner.script([
        {:ok, %Runner.Result{run_id: 0, subtype: "success", structured_output: %{...}}},
        fn spec -> assert spec.model == "opus"; {:ok, ...} end
      ])

  Every received `RunSpec` is recorded (`executed_specs/0`). Like the real
  runner, it creates a `runs` row so workers can associate triages/plans.
  """

  @behaviour Harness.Runs.Runner

  alias Harness.Runs
  alias Harness.Runs.Runner.Result

  def start_link do
    Agent.start_link(fn -> %{responses: [], specs: []} end, name: __MODULE__)
  end

  def script(responses) do
    ensure_started()
    Agent.update(__MODULE__, &%{&1 | responses: responses, specs: []})
  end

  def executed_specs do
    Agent.get(__MODULE__, & &1.specs) |> Enum.reverse()
  end

  @impl true
  def execute(spec, _opts) do
    ensure_started()

    response =
      Agent.get_and_update(__MODULE__, fn state ->
        case state.responses do
          [next | rest] -> {next, %{state | responses: rest, specs: [spec | state.specs]}}
          [] -> {:no_response, %{state | specs: [spec | state.specs]}}
        end
      end)

    run =
      Runs.create_run!(%{
        kind: to_string(spec.kind),
        ref: spec.ref,
        issue_id: spec.issue_id,
        model: spec.model,
        status: "running",
        worktree: spec.worktree
      })

    outcome =
      case response do
        :no_response ->
          raise "FakeRunner script exhausted — unexpected execute: #{inspect(spec.kind)}"

        fun when is_function(fun, 1) ->
          fun.(spec)

        canned ->
          canned
      end

    case outcome do
      {:ok, %Result{} = result} ->
        Runs.update_run!(run, %{
          status: "succeeded",
          result_subtype: result.subtype,
          turns: result.turns,
          ended_at: DateTime.utc_now()
        })

        {:ok, %{result | run_id: run.id}}

      {:error, reason} = error ->
        Runs.update_run!(run, %{
          status: "failed",
          error: inspect(reason),
          ended_at: DateTime.utc_now()
        })

        error
    end
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, _} = start_link()
        :ok

      _ ->
        :ok
    end
  end
end
