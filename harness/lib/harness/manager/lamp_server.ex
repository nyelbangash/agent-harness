defmodule Harness.Manager.LampServer do
  @moduledoc """
  Owns an ETS table tracking the current state of each anomaly-class lamp.
  Lamps survive across manager sweeps; on app restart they start cleared
  and are re-detected within the first sweep (default 5 minutes).

  PubSub broadcasts on `"manager_lamps"` after every set/clear so OverviewLive
  receives live updates without polling.
  """

  use GenServer

  @lamps ~w(loop_signature wedged_lane stalled_run stranded_state artifact_drift telemetry_silence stale_code)a
  @topic "manager_lamps"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Set a lamp :on with optional detail string."
  def set(lamp, detail \\ nil), do: GenServer.call(__MODULE__, {:set, lamp, detail})

  @doc "Set a lamp :off."
  def clear(lamp), do: GenServer.call(__MODULE__, {:clear, lamp})

  @doc "Return all lamp states as a list of maps."
  def get_all, do: GenServer.call(__MODULE__, :get_all)

  @doc "Timestamp of the last completed sweep, or nil before the first."
  def last_sweep_at, do: GenServer.call(__MODULE__, :last_sweep_at)

  @doc "Record that a sweep just completed."
  def record_sweep, do: GenServer.cast(__MODULE__, :record_sweep)

  @doc "Subscribe to lamp change events on the manager_lamps PubSub topic."
  def subscribe, do: Phoenix.PubSub.subscribe(Harness.PubSub, @topic)

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(:ok) do
    table = :ets.new(:manager_lamps, [:named_table, :public, read_concurrency: true])

    for lamp <- @lamps do
      :ets.insert(table, {lamp, :off, nil, nil, nil})
    end

    {:ok, %{table: table, last_sweep_at: nil}}
  end

  @impl true
  def handle_call({:set, lamp, detail}, _from, state) do
    now = DateTime.utc_now()
    :ets.insert(state.table, {lamp, :on, now, nil, detail})
    broadcast(state.table)
    {:reply, :ok, state}
  end

  def handle_call({:clear, lamp}, _from, state) do
    now = DateTime.utc_now()

    {set_at, detail} =
      case :ets.lookup(state.table, lamp) do
        [{_, _, set_at, _, detail}] -> {set_at, detail}
        [] -> {nil, nil}
      end

    :ets.insert(state.table, {lamp, :off, set_at, now, detail})
    broadcast(state.table)
    {:reply, :ok, state}
  end

  def handle_call(:get_all, _from, state) do
    {:reply, format_lamps(state.table), state}
  end

  def handle_call(:last_sweep_at, _from, state) do
    {:reply, state.last_sweep_at, state}
  end

  @impl true
  def handle_cast(:record_sweep, state) do
    {:noreply, %{state | last_sweep_at: DateTime.utc_now()}}
  end

  # -- helpers ----------------------------------------------------------------

  defp broadcast(table) do
    Phoenix.PubSub.broadcast(Harness.PubSub, @topic, {:lamps_updated, format_lamps(table)})
  end

  defp format_lamps(table) do
    for lamp <- @lamps do
      case :ets.lookup(table, lamp) do
        [{_, status, set_at, cleared_at, detail}] ->
          %{class: lamp, status: status, set_at: set_at, cleared_at: cleared_at, detail: detail}

        [] ->
          %{class: lamp, status: :off, set_at: nil, cleared_at: nil, detail: nil}
      end
    end
  end
end
