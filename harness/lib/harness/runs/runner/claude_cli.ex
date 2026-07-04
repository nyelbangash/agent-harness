defmodule Harness.Runs.Runner.ClaudeCLI do
  @moduledoc """
  The real runner: creates the `runs` row, starts a `RunServer` under
  `RunSupervisor`, and blocks until the session finishes (or is killed).
  """

  @behaviour Harness.Runs.Runner

  alias Harness.Runs

  @impl true
  def execute(spec, _opts) do
    run =
      Runs.create_run!(%{
        kind: to_string(spec.kind),
        ref: spec.ref,
        issue_id: spec.issue_id,
        model: spec.model,
        status: "queued",
        worktree: spec.worktree
      })

    case Harness.Runs.RunSupervisor.start_run(spec, run) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        try do
          result = Harness.Runs.RunServer.await(pid)
          Process.demonitor(ref, [:flush])
          result
        catch
          :exit, reason ->
            Runs.update_run!(Runs.get_run!(run.id), %{
              status: "failed",
              error: "runner crashed: #{inspect(reason)}",
              ended_at: DateTime.utc_now()
            })

            {:error, :runner_crash}
        end

      {:error, reason} ->
        Runs.update_run!(run, %{
          status: "failed",
          error: "could not start run server: #{inspect(reason)}",
          ended_at: DateTime.utc_now()
        })

        {:error, {:start_failed, reason}}
    end
  end
end
