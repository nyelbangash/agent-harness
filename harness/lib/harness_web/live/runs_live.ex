defmodule HarnessWeb.RunsLive do
  @moduledoc """
  Run console (spec §12.3): session table + detail pane with the live
  streaming transcript (mono, tool calls collapsed by default) and a kill
  button that means it.
  """

  use HarnessWeb, :live_view

  alias Harness.Runs

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runs.subscribe()
      :timer.send_interval(5_000, :queue_tick)
    end

    {:ok,
     socket
     |> assign(:page_title, "Runs")
     |> assign(:selected, nil)
     |> stream(:events, [])
     |> assign(:runs, Runs.recent_runs(100))
     |> assign(:queues, Runs.queue_stats())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params["id"] do
        nil ->
          assign(socket, :selected, nil)

        id ->
          run = Runs.get_run!(String.to_integer(id))
          if connected?(socket), do: Runs.subscribe(run.id)

          socket
          |> assign(:selected, run)
          |> stream(:events, Runs.events(run.id), reset: true)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:run_started, _run}, socket) do
    {:noreply,
     socket
     |> assign(:runs, Runs.recent_runs(100))
     |> assign(:queues, Runs.queue_stats())}
  end

  def handle_info(:queue_tick, socket) do
    {:noreply, assign(socket, :queues, Runs.queue_stats())}
  end

  def handle_info({:run_updated, run}, socket) do
    socket =
      socket
      |> assign(:runs, Runs.recent_runs(100))
      |> assign(:queues, Runs.queue_stats())

    socket =
      if socket.assigns.selected && socket.assigns.selected.id == run.id do
        assign(socket, :selected, run)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:run_counters, run_id, turns}, socket) do
    runs =
      Enum.map(socket.assigns.runs, fn
        %{id: ^run_id, status: "running"} = run -> %{run | turns: turns}
        run -> run
      end)

    {:noreply, assign(socket, :runs, runs)}
  end

  def handle_info({:run_event, event}, socket) do
    if socket.assigns.selected && event.run_id == socket.assigns.selected.id do
      {:noreply, stream_insert(socket, :events, event)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path="/runs"
      mode={@mode}
      usage_mode={@usage_mode}
      usage_health={@usage_health}
    >
      <div class="page-fit md:flex md:flex-col md:min-h-0 md:overflow-hidden">
        <h1 class="font-display uppercase tracking-[0.16em] text-sm text-ink-dim mb-4">Runs</h1>

        <div
          :if={@queues != []}
          aria-label="queues"
          class="flex flex-wrap items-center gap-x-8 gap-y-2 mb-6"
        >
          <div :for={q <- @queues} class="flex items-center gap-2 font-mono text-[11px] tabular-nums">
            <span class="font-display uppercase tracking-[0.14em] text-[10px] text-ink-dim">
              {q.label}
            </span>
            <span aria-hidden="true"><span
              :for={i <- 1..max(q.limit, 1)//1}
              class={if i <= q.running, do: "text-accent", else: "text-ink-dim/30"}
            >▮</span></span>
            <span class="text-ink">{q.running}/{q.limit}</span>
            <span class="text-ink-dim">· {q.waiting} waiting</span>
          </div>
        </div>

        <div class="grid gap-8 xl:grid-cols-2 md:flex-1 md:min-h-0 md:auto-rows-fr">
          <section aria-label="sessions" class="md:flex md:flex-col md:min-h-0">
            <div class="md:flex-1 md:min-h-0 md:overflow-y-auto">
              <table class="w-full text-left tabular">
                <thead class="sticky top-0 bg-bg">
                  <tr class="font-display uppercase tracking-[0.14em] text-[10px] text-ink-dim border-b border-surface-2">
                    <th class="py-2 pr-2">#</th>
                    <th class="py-2 pr-2">Kind</th>
                    <th class="py-2 pr-2">Ref</th>
                    <th class="py-2 pr-2">Model</th>
                    <th class="py-2 pr-2 text-right">Turns</th>
                    <th class="py-2 pr-2 text-right">Tokens</th>
                    <th class="py-2 pr-2 text-right">Time</th>
                    <th class="py-2">Status</th>
                  </tr>
                </thead>
                <tbody class="font-mono text-xs">
                  <tr
                    :for={run <- @runs}
                    class={[
                      "border-b border-surface-2/60 cursor-pointer hover:bg-surface",
                      @selected && @selected.id == run.id && "bg-surface"
                    ]}
                    phx-click={JS.patch(~p"/runs/#{run.id}")}
                  >
                    <td class="py-2 pr-2 text-ink-dim">{run.id}</td>
                    <td class="py-2 pr-2 uppercase text-[10px] font-display tracking-wide text-ink">
                      {run.kind}
                    </td>
                    <td class="py-2 pr-2 text-ink-dim truncate max-w-[16ch]">{run.ref}</td>
                    <td class="py-2 pr-2 text-ink-dim">{run.model}</td>
                    <td class="py-2 pr-2 text-right">{run.turns}</td>
                    <td class="py-2 pr-2 text-right">{run.tokens_out}</td>
                    <td class="py-2 pr-2 text-right">{duration(run)}</td>
                    <td class="py-2">
                      <span class={status_class(run.status)}>{run.status}</span>
                      <% badge = reason_badge(run) %>
                      <span
                        :if={badge}
                        class="ml-1.5 font-display text-[9px] uppercase tracking-widest text-alert/70"
                      >{badge}</span>
                    </td>
                  </tr>
                </tbody>
              </table>
              <p :if={@runs == []} class="font-body text-sm text-ink-dim py-4">
                No sessions yet.
              </p>
            </div>
          </section>

          <section
            :if={@selected}
            aria-label="transcript"
            class="min-w-0 md:flex md:flex-col md:min-h-0"
          >
            <div class="flex items-center gap-3 mb-3">
              <h2 class="font-display uppercase tracking-[0.16em] text-[12px] text-ink-dim">
                Run #{@selected.id} · {@selected.kind} · {@selected.ref}
              </h2>
              <span class={status_class(@selected.status)}>{@selected.status}</span>
              <span
                :if={reason_badge(@selected)}
                class="font-display text-[9px] uppercase tracking-widest text-alert/70"
              >{reason_badge(@selected)}</span>
              <button
                :if={@selected.status == "running"}
                phx-click="kill_run"
                phx-value-id={@selected.id}
                data-confirm={"Kill run ##{@selected.id}?"}
                class="ml-auto font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-alert text-alert rounded-sm hover:bg-alert hover:text-ink"
              >
                Kill
              </button>
            </div>

            <div class="font-mono text-[11px] text-ink-dim mb-3 tabular-nums">
              model {@selected.model} · {@selected.turns} turns · {@selected.tokens_in}/{@selected.tokens_out} tok ·
              ${:erlang.float_to_binary(@selected.cost_estimate || 0.0, decimals: 3)} est.
            </div>

            <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoScroll">
              // Pin-to-bottom: follow the stream only while the reader is already
              // at the bottom; never fight an upward scroll into history.
              export default {
                mounted() { this.scrollToEnd() },
                beforeUpdate() {
                  const el = this.el
                  this.pinned = el.scrollHeight - el.clientHeight - el.scrollTop < 60
                },
                updated() { if (this.pinned) this.scrollToEnd() },
                scrollToEnd() { this.el.scrollTop = this.el.scrollHeight }
              }
            </script>
            <div
              id="transcript"
              phx-update="stream"
              phx-hook=".AutoScroll"
              class="space-y-1 max-h-[70vh] md:max-h-none md:flex-1 md:min-h-0 overflow-y-auto rounded-sm bg-surface border border-surface-2 p-3"
            >
              <div :for={{dom_id, event} <- @streams.events} id={dom_id}>
                <.event event={event} />
              </div>
            </div>
          </section>

          <section :if={!@selected} class="hidden xl:block">
            <p class="font-body text-sm text-ink-dim">Select a session to stream its transcript.</p>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :event, :map, required: true

  defp event(%{event: %{type: "text"}} = assigns) do
    ~H"""
    <div class="font-mono text-xs text-ink whitespace-pre-wrap py-0.5">{assistant_text(@event)}</div>
    """
  end

  defp event(%{event: %{type: type}} = assigns) when type in ["tool_use", "tool_result"] do
    ~H"""
    <details class="font-mono text-[11px] text-ink-dim">
      <summary class="cursor-pointer select-none py-0.5">
        <span class="text-accent">{if @event.type == "tool_use", do: "→", else: "←"}</span>
        {tool_label(@event)}
      </summary>
      <pre class="whitespace-pre-wrap break-all text-[10px] pl-4 py-1 opacity-80">{Jason.encode!(@event.payload, pretty: true) |> String.slice(0, 4_000)}</pre>
    </details>
    """
  end

  defp event(%{event: %{type: "error"}} = assigns) do
    ~H"""
    <div class="font-mono text-[11px] text-alert py-0.5">
      ✗ {inspect(@event.payload["subtype"] || @event.payload["note"] || "error")}
    </div>
    """
  end

  defp event(assigns) do
    ~H"""
    <div class="font-mono text-[10px] text-ink-dim/60 py-0.5">
      · {@event.payload["subtype"] || @event.payload["type"]}
    </div>
    """
  end

  defp assistant_text(event) do
    (get_in(event.payload, ["message", "content"]) || [])
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp tool_label(%{type: "tool_use"} = event) do
    (get_in(event.payload, ["message", "content"]) || [])
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_use"))
    |> Enum.map_join(", ", & &1["name"])
    |> case do
      "" -> "tool call"
      names -> names
    end
  end

  defp tool_label(_event), do: "tool result"

  defp duration(%{started_at: %DateTime{} = s, ended_at: %DateTime{} = e}),
    do: "#{DateTime.diff(e, s, :second)}s"

  defp duration(%{started_at: %DateTime{} = s, status: "running"}),
    do: "#{DateTime.diff(DateTime.utc_now(), s, :second)}s…"

  defp duration(_), do: "—"

  defp status_class("succeeded"), do: "font-mono text-[10px] uppercase text-ok"

  defp status_class(status) when status in ["failed", "killed"],
    do: "font-mono text-[10px] uppercase text-alert"

  defp status_class("running"), do: "font-mono text-[10px] uppercase text-accent"
  defp status_class(_), do: "font-mono text-[10px] uppercase text-ink-dim"

  # Maps run.error / result_subtype to a short human-readable badge, or nil
  # when the status carries enough information on its own.
  defp reason_badge(%{status: status, error: error, result_subtype: subtype})
       when status in ["killed", "failed"] do
    cond do
      is_binary(error) and String.starts_with?(error, "turn cap ") ->
        error

      is_binary(error) and error =~ "operator" ->
        "operator kill"

      is_binary(error) and (error =~ "reaped" or error =~ "daemon shutdown") ->
        "orphaned by restart"

      is_binary(error) and error =~ "timeout" ->
        "timeout"

      is_binary(error) and error =~ "no result envelope" ->
        "crashed"

      is_binary(subtype) and subtype != "success" ->
        String.replace(subtype, "_", " ")

      true ->
        nil
    end
  end

  defp reason_badge(_), do: nil
end
