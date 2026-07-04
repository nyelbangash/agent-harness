defmodule Harness.Policy.Watcher do
  @moduledoc """
  Watches the directory containing `policy.yaml` and triggers a hot reload
  when the file changes. Watching the directory (not the file) survives
  editors that replace-on-save. macOS fsevents can coalesce bursts, so
  reloads are debounced.
  """

  use GenServer
  require Logger

  @debounce_ms 200

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    policy_path = Application.fetch_env!(:harness, :policy_path)

    case FileSystem.start_link(dirs: [Path.dirname(policy_path)]) do
      {:ok, watcher} ->
        FileSystem.subscribe(watcher)
        {:ok, %{policy_path: Path.expand(policy_path), timer: nil}}

      {:error, reason} ->
        Logger.warning("policy watcher disabled (#{inspect(reason)}); edits need `Policy.reload/0`")
        :ignore
    end
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    if Path.expand(path) == state.policy_path do
      if state.timer, do: Process.cancel_timer(state.timer)
      {:noreply, %{state | timer: Process.send_after(self(), :reload, @debounce_ms)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  def handle_info(:reload, state) do
    Harness.Policy.Server.reload()
    {:noreply, %{state | timer: nil}}
  end
end
