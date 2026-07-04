defmodule Harness.Notify.TestBackend do
  @moduledoc "Captures notifications and forwards them to a subscribed test process."

  @behaviour Harness.Notify.Backend

  @impl true
  def deliver(event, title, message, _opts) do
    for pid <- List.wrap(:persistent_term.get({__MODULE__, :subscribers}, [])) do
      send(pid, {:notify, event, title, message})
    end

    :ok
  end

  @doc "Route captured notifications to the calling test process."
  def subscribe do
    :persistent_term.put({__MODULE__, :subscribers}, [self()])
    :ok
  end
end
