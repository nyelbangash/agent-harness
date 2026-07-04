defmodule HarnessWeb.IdeationLive do
  @moduledoc """
  Ideation view (spec §12.4): session list, an interactive SVG tree (node
  color by score, pruned branches dimmed not hidden), a click-to-read artifact
  side panel, the journal strip along the bottom, and a start-session form.
  """

  use HarnessWeb, :live_view

  alias Harness.Ideation
  alias Harness.Ideation.Layout

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Ideation.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Ideation")
     |> assign(:sessions, Ideation.list_sessions())
     |> assign(:selected_node, nil)
     |> assign(:form, to_form(%{"seed_prompt" => "", "budget_minutes" => "180"}))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["id"] do
      nil ->
        {:noreply,
         assign(socket, session: nil, tree_layout: nil, journal: nil, selected_node: nil)}

      id ->
        # navigating to a session starts with no artifact open
        if connected?(socket), do: Ideation.subscribe(String.to_integer(id))

        {:noreply, socket |> assign(:selected_node, nil) |> load_session(String.to_integer(id))}
    end
  end

  # does NOT touch :selected_node, so a live tree update preserves the
  # operator's open artifact panel
  defp load_session(socket, id) do
    session = Ideation.get_session!(id)
    ideas = Ideation.tree(id)

    socket
    |> assign(:session, session)
    |> assign(:tree_layout, Layout.compute(ideas))
    |> assign(:journal, Ideation.read_journal(session))
  end

  @impl true
  def handle_event("start", %{"seed_prompt" => seed} = params, socket) do
    seed = String.trim(seed)

    if seed == "" do
      {:noreply, put_flash(socket, :error, "Give it a seed idea first.")}
    else
      budget = parse_int(params["budget_minutes"], 180)
      {session, _root} = Ideation.start_session(%{seed_prompt: seed, budget_minutes: budget})
      {:noreply, push_patch(socket, to: ~p"/ideation/#{session.id}")}
    end
  end

  def handle_event("select_node", %{"id" => id}, socket) do
    idea = Ideation.get_idea!(String.to_integer(id))

    {:noreply,
     assign(socket, :selected_node, %{idea: idea, artifact: Ideation.read_artifact(idea)})}
  end

  def handle_event("stop_session", %{"id" => id}, socket) do
    id |> String.to_integer() |> Ideation.get_session!() |> Ideation.stop_session!(:operator)
    {:noreply, put_flash(socket, :info, "Session stopping after the current iteration.")}
  end

  @impl true
  def handle_info({event, _}, socket)
      when event in [:session_started, :session_updated] do
    socket = assign(socket, :sessions, Ideation.list_sessions())

    socket =
      if socket.assigns[:session],
        do: load_session(socket, socket.assigns.session.id),
        else: socket

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path="/ideation"
      mode={@mode}
      usage_mode={@usage_mode}
      usage_health={@usage_health}
    >
      <div class="grid lg:grid-cols-4 gap-6">
        <aside class="lg:col-span-1 space-y-4">
          <form phx-submit="start" class="space-y-2">
            <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim">
              Seed a session
            </h2>
            <textarea
              name="seed_prompt"
              rows="4"
              placeholder="One broad product or feature thought…"
              class="w-full bg-surface border border-surface-2 rounded-sm px-2 py-1.5 font-body text-sm text-ink focus:outline-2 focus:outline-accent"
            ></textarea>
            <div class="flex items-center gap-2">
              <label class="font-mono text-[11px] text-ink-dim">budget min</label>
              <input
                type="number"
                name="budget_minutes"
                value="180"
                min="1"
                class="w-20 bg-surface border border-surface-2 rounded-sm px-2 py-1 font-mono text-xs text-ink"
              />
              <button class="ml-auto font-display uppercase text-[10px] tracking-widest px-3 py-1.5 bg-accent text-bg rounded-sm">
                Start
              </button>
            </div>
          </form>

          <div>
            <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-2">
              Sessions
            </h2>
            <p :if={@sessions == []} class="font-body text-sm text-ink-dim">
              No sessions yet — seed one idea and give it three hours.
            </p>
            <.link
              :for={s <- @sessions}
              patch={~p"/ideation/#{s.id}"}
              class={[
                "block rounded-sm border px-3 py-2 mb-1.5",
                @session && @session.id == s.id && "border-accent bg-surface",
                !(@session && @session.id == s.id) && "border-surface-2 hover:bg-surface"
              ]}
            >
              <div class="flex items-center gap-2">
                <span class="font-mono text-[10px] text-ink-dim tabular-nums">#{s.id}</span>
                <span class={session_status_class(s.status)}>{s.status}</span>
                <span class="font-mono text-[10px] text-ink-dim ml-auto tabular-nums">
                  {s.iterations}it
                </span>
              </div>
              <p class="font-body text-[12px] text-ink mt-1 line-clamp-2">{s.seed_prompt}</p>
            </.link>
          </div>
        </aside>

        <section class="lg:col-span-3">
          <div :if={!@session} class="font-body text-sm text-ink-dim">
            Select a session to watch its idea tree grow.
          </div>

          <div :if={@session}>
            <div class="flex items-center gap-3 mb-4">
              <h1 class="font-display uppercase tracking-[0.16em] text-sm text-ink-dim">
                Session #{@session.id}
              </h1>
              <span class={session_status_class(@session.status)}>{@session.status}</span>
              <span :if={@session.stop_reason} class="font-mono text-[10px] text-ink-dim">
                {String.replace(@session.stop_reason, "_", " ")}
              </span>
              <button
                :if={@session.status == "running"}
                phx-click="stop_session"
                phx-value-id={@session.id}
                data-confirm="Stop this ideation session?"
                class="ml-auto font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-alert text-alert rounded-sm hover:bg-alert hover:text-ink"
              >
                Stop
              </button>
            </div>

            <div class="grid xl:grid-cols-3 gap-4">
              <div class="xl:col-span-2 rounded-sm bg-surface border border-surface-2 overflow-auto max-h-[60vh]">
                <svg
                  viewBox={"0 0 #{@tree_layout.width} #{@tree_layout.height}"}
                  class="w-full"
                  style="min-height: 300px"
                >
                  <line
                    :for={e <- @tree_layout.edges}
                    x1={e.x1}
                    y1={e.y1}
                    x2={e.x2}
                    y2={e.y2}
                    stroke="var(--color-surface-2)"
                    stroke-width="1.5"
                  />
                  <g
                    :for={n <- @tree_layout.nodes}
                    phx-click="select_node"
                    phx-value-id={n.id}
                    class="cursor-pointer"
                    opacity={if n.status == "pruned", do: "0.3", else: "1"}
                  >
                    <circle
                      cx={n.x}
                      cy={n.y}
                      r="11"
                      fill={score_fill(n.score)}
                      stroke={
                        if @selected_node && @selected_node.idea.id == n.id,
                          do: "var(--color-ink)",
                          else: "var(--color-bg)"
                      }
                      stroke-width="2"
                    />
                    <text
                      x={n.x}
                      y={n.y + 26}
                      text-anchor="middle"
                      class="font-mono"
                      font-size="9"
                      fill="var(--color-ink-dim)"
                    >
                      {String.slice(n.title, 0, 16)}
                    </text>
                  </g>
                </svg>
              </div>

              <div class="rounded-sm bg-surface border border-surface-2 p-3 max-h-[60vh] overflow-auto">
                <div :if={!@selected_node} class="font-body text-sm text-ink-dim">
                  Click a node to read its artifact.
                </div>
                <div :if={@selected_node}>
                  <div class="flex items-center gap-2 mb-2">
                    <span class="font-display text-sm text-ink">{@selected_node.idea.title}</span>
                    <span class="font-mono text-[10px] text-ink-dim tabular-nums ml-auto">
                      score {@selected_node.idea.score} · d{@selected_node.idea.depth}
                    </span>
                  </div>
                  <p class="font-body text-[13px] text-ink-dim mb-2">{@selected_node.idea.summary}</p>
                  <pre
                    :if={@selected_node.artifact}
                    class="font-body text-[12px] text-ink whitespace-pre-wrap leading-relaxed"
                  >{@selected_node.artifact}</pre>
                </div>
              </div>
            </div>

            <div class="mt-4 rounded-sm bg-surface border border-surface-2 p-3">
              <h3 class="font-display uppercase tracking-[0.14em] text-[10px] text-ink-dim mb-1">
                Journal
              </h3>
              <pre class="font-mono text-[11px] text-ink-dim whitespace-pre-wrap max-h-40 overflow-auto">{@journal}</pre>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # score → color ramp: low = dim, high = accent (no red/green — those are
  # status colors)
  defp score_fill(score) when score >= 7.5, do: "var(--color-accent)"
  defp score_fill(score) when score >= 5.0, do: "#5f7487"
  defp score_fill(_), do: "var(--color-surface-2)"

  defp session_status_class("running"), do: "font-mono text-[10px] uppercase text-accent"
  defp session_status_class("synthesized"), do: "font-mono text-[10px] uppercase text-ok"
  defp session_status_class(_), do: "font-mono text-[10px] uppercase text-ink-dim"
end
