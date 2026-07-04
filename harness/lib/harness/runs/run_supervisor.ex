defmodule Harness.Runs.RunSupervisor do
  @moduledoc """
  Owns one `RunServer` per live agent session (spec §6). Killing a run goes
  through the RunServer, which signals the OS process and marks the run
  `killed`; transient restarts are disabled — a crashed run is a failed run,
  not one to silently re-execute.
  """

  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_run(spec, run) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Harness.Runs.RunServer, {spec, run}}
    )
  end
end
