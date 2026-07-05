defmodule HarnessWeb.RailHooks do
  @moduledoc """
  Shared behavior for every Mission Control LiveView: the left rail's state
  (mode + usage health), the master-kill and per-run kill events, and the
  current path for nav highlighting. Domain messages pass through to each
  LiveView's own `handle_info`.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Harness.PubSub, "policy")
      Phoenix.PubSub.subscribe(Harness.PubSub, "usage")
      # staleness is a silent time-based transition (no broadcast fires when
      # the last sample ages out) — refresh the rail on a slow tick
      :timer.send_interval(60_000, self(), :rail_tick)
    end

    socket =
      socket
      |> assign(rail_state())
      |> assign(:current_path, "/")
      |> attach_hook(:rail_path, :handle_params, &handle_params/3)
      |> attach_hook(:rail_events, :handle_event, &handle_event/3)
      |> attach_hook(:rail_info, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_params(_params, uri, socket) do
    {:cont, assign(socket, :current_path, URI.parse(uri).path || "/")}
  end

  defp handle_event("master_kill", _params, socket) do
    Harness.Runs.kill_all()
    {:halt, put_flash(socket, :info, "Kill signal sent to every running session")}
  end

  defp handle_event("kill_run", %{"id" => id}, socket) do
    case Harness.Runs.kill(String.to_integer(id)) do
      :ok -> {:halt, put_flash(socket, :info, "Kill signal sent to run ##{id}")}
      {:error, :not_running} -> {:halt, put_flash(socket, :error, "Run ##{id} is not running")}
    end
  end

  defp handle_event("set_mode", %{"mode" => mode}, socket)
       when mode in ["plan_only", "full_auto", "paused"] do
    :ok = Harness.Policy.set_mode!(String.to_existing_atom(mode))

    {:halt,
     socket
     |> assign(rail_state())
     |> put_flash(:info, "Mode set to #{String.replace(mode, "_", " ")}")}
  end

  defp handle_event("promote_to_auto", %{"id" => id}, socket) do
    issue_id = String.to_integer(id)

    case Harness.GitHub.promote_to_auto(issue_id) do
      {:ok, _issue} ->
        {:halt, put_flash(socket, :info, "Promoted to auto — implement session queued")}

      {:already_queued, _issue} ->
        {:halt, put_flash(socket, :info, "Already queued for implementation")}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info(:rail_tick, socket), do: {:halt, assign(socket, rail_state())}
  defp handle_info({:policy_reloaded, _}, socket), do: {:cont, assign(socket, rail_state())}
  defp handle_info({:policy_error, _}, socket), do: {:cont, assign(socket, rail_state())}
  defp handle_info({:usage_mode_changed, _}, socket), do: {:cont, assign(socket, rail_state())}
  defp handle_info({:usage_sample, _}, socket), do: {:cont, assign(socket, rail_state())}
  defp handle_info(_message, socket), do: {:cont, socket}

  defp rail_state do
    %{
      mode: Harness.Policy.mode(),
      usage_mode: Harness.Usage.current_mode(),
      usage_health: Harness.Usage.health()
    }
  end
end
