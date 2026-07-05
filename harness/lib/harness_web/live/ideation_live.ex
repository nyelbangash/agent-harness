defmodule HarnessWeb.IdeationLive do
  @moduledoc """
  Ideation view (spec §12.4): session list, an interactive SVG tree (node
  color by score, pruned branches dimmed not hidden), a click-to-read artifact
  side panel, the journal strip along the bottom, and a start-session form.
  """

  use HarnessWeb, :live_view

  alias Harness.Ideation
  alias Harness.Ideation.Layout
  alias Harness.Policy

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Ideation.subscribe()

    policy = Policy.get()
    now = parse_connect_now(get_connect_params(socket))
    budget = policy.ideate.default_budget_minutes

    {:ok,
     socket
     |> assign(:page_title, "Ideation")
     |> assign(:sessions, Ideation.list_sessions())
     |> assign(:selected_node, nil)
     |> assign(:artifact_open, false)
     |> assign(:policy, policy)
     |> assign(:window_note, Policy.window_note(policy: policy, now: now))
     |> assign(:budget_minutes, budget)
     |> assign(:form, to_form(%{"seed_prompt" => "", "budget_minutes" => "#{budget}"}))}
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

        {:noreply,
         socket
         |> assign(:selected_node, nil)
         |> assign(:artifact_open, false)
         |> load_session(String.to_integer(id))}
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

  def handle_event("fill_seed", %{"seed" => seed}, socket) do
    form =
      to_form(%{
        "seed_prompt" => seed,
        "budget_minutes" => to_string(socket.assigns.budget_minutes)
      })

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("form_change", params, socket) do
    budget = parse_int(params["budget_minutes"], socket.assigns.budget_minutes)

    form =
      to_form(%{
        "seed_prompt" => params["seed_prompt"] || "",
        "budget_minutes" => to_string(budget)
      })

    {:noreply, socket |> assign(:budget_minutes, budget) |> assign(:form, form)}
  end

  @impl true
  def handle_event("start", %{"seed_prompt" => seed} = params, socket) do
    seed = String.trim(seed)

    if seed == "" do
      {:noreply, put_flash(socket, :error, "Give it a seed idea first.")}
    else
      budget = parse_int(params["budget_minutes"], 180)
      {session, _root} = Ideation.start_session(%{seed_prompt: seed, budget_minutes: budget})

      {:noreply,
       socket
       |> assign(:form, to_form(%{"seed_prompt" => "", "budget_minutes" => to_string(budget)}))
       |> push_patch(to: ~p"/ideation/#{session.id}")}
    end
  end

  def handle_event("select_node", %{"id" => id}, socket) do
    idea = Ideation.get_idea!(String.to_integer(id))
    artifact = Ideation.read_artifact(idea)

    {:noreply,
     socket
     |> assign(:selected_node, %{idea: idea, artifact: artifact})
     |> assign(:artifact_open, artifact != nil)}
  end

  def handle_event("close_artifact", _params, socket) do
    {:noreply, assign(socket, :artifact_open, false)}
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

  def handle_info({:policy_reloaded, _}, socket) do
    policy = Policy.get()
    now = NaiveDateTime.local_now() |> NaiveDateTime.to_time()

    {:noreply,
     socket
     |> assign(:policy, policy)
     |> assign(:window_note, Policy.window_note(policy: policy, now: now))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp parse_connect_now(nil), do: NaiveDateTime.local_now() |> NaiveDateTime.to_time()

  defp parse_connect_now(params) do
    case params["test_now"] do
      nil ->
        NaiveDateTime.local_now() |> NaiveDateTime.to_time()

      hhmm ->
        case Time.from_iso8601(hhmm <> ":00") do
          {:ok, t} -> t
          _ -> NaiveDateTime.local_now() |> NaiveDateTime.to_time()
        end
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  # best-effort markdown → HTML; Earmark still returns usable HTML alongside
  # errors, and artifacts are locally-generated content
  defp artifact_html(md) do
    case Earmark.as_html(md) do
      {:ok, html, _} -> Phoenix.HTML.raw(html)
      {:error, html, _} -> Phoenix.HTML.raw(html)
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
      <div class="page-fit md:flex md:flex-col md:min-h-0 md:overflow-hidden">
        <div class="grid lg:grid-cols-4 gap-6 md:flex-1 md:min-h-0 md:auto-rows-fr">
          <aside class="lg:col-span-1 space-y-4 md:flex md:flex-col md:min-h-0">
            <form phx-submit="start" phx-change="form_change" class="space-y-2">
              <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim">
                Seed a session
              </h2>
              <textarea
                name="seed_prompt"
                rows="4"
                placeholder="One broad product or feature thought…"
                class="w-full bg-surface border border-surface-2 rounded-sm px-2 py-1.5 font-body text-sm text-ink focus:outline-2 focus:outline-accent"
              >{@form[:seed_prompt].value}</textarea>
              <div class="flex items-center gap-2">
                <label class="font-mono text-[11px] text-ink-dim">budget</label>
                <input
                  type="range"
                  name="budget_minutes"
                  value={@budget_minutes}
                  min="30"
                  max="360"
                  step="30"
                  class="flex-1 accent-accent"
                />
                <span class="font-mono text-[11px] text-ink-dim tabular-nums w-14 text-right">
                  {@budget_minutes} min
                </span>
                <button class="font-display uppercase text-[10px] tracking-widest px-3 py-1.5 bg-accent text-bg rounded-sm">
                  Start
                </button>
              </div>
              <div class="font-mono text-[10px] text-ink-dim/70 mt-1 space-y-0.5">
                <div>ideate: {@policy.models.ideate} · critique: {@policy.models.critique}</div>
                <div class={
                  if String.starts_with?(@window_note, "starts"), do: "text-ok", else: "text-accent"
                }>
                  {@window_note}
                </div>
              </div>
            </form>

            <div class="md:flex-1 md:min-h-0 md:overflow-y-auto">
              <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-2">
                Sessions
              </h2>
              <p :if={@sessions == []} class="font-body text-sm text-ink-dim">
                No sessions yet — seed one idea and give it three hours.
              </p>
              <.link
                :for={s <- @sessions}
                patch={
                  if @session && @session.id == s.id,
                    do: ~p"/ideation",
                    else: ~p"/ideation/#{s.id}"
                }
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

          <section class="lg:col-span-3 md:flex md:flex-col md:min-h-0">
            <div :if={!@session} class="space-y-8 py-4">
              <div>
                <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-3">
                  How ideation works
                </h2>
                <svg
                  viewBox="0 0 320 80"
                  class="w-full max-w-sm"
                  aria-label="Ideation loop: diverge, develop, critique, synthesize"
                >
                  <defs>
                    <marker id="arr" markerWidth="6" markerHeight="6" refX="5" refY="3" orient="auto">
                      <path d="M0,0 L6,3 L0,6 Z" fill="var(--color-surface-2)" />
                    </marker>
                  </defs>
                  <line
                    x1="46"
                    y1="40"
                    x2="74"
                    y2="40"
                    stroke="var(--color-surface-2)"
                    stroke-width="1.5"
                    marker-end="url(#arr)"
                  />
                  <line
                    x1="126"
                    y1="40"
                    x2="154"
                    y2="40"
                    stroke="var(--color-surface-2)"
                    stroke-width="1.5"
                    marker-end="url(#arr)"
                  />
                  <line
                    x1="206"
                    y1="40"
                    x2="234"
                    y2="40"
                    stroke="var(--color-surface-2)"
                    stroke-width="1.5"
                    marker-end="url(#arr)"
                  />
                  <circle
                    cx="30"
                    cy="40"
                    r="14"
                    fill="var(--color-surface)"
                    stroke="var(--color-accent)"
                    stroke-width="1.5"
                  />
                  <circle
                    cx="110"
                    cy="40"
                    r="14"
                    fill="var(--color-surface)"
                    stroke="var(--color-surface-2)"
                    stroke-width="1.5"
                  />
                  <circle
                    cx="190"
                    cy="40"
                    r="14"
                    fill="var(--color-surface)"
                    stroke="var(--color-surface-2)"
                    stroke-width="1.5"
                  />
                  <circle
                    cx="270"
                    cy="40"
                    r="14"
                    fill="var(--color-surface)"
                    stroke="var(--color-ok)"
                    stroke-width="1.5"
                  />
                  <text
                    x="30"
                    y="64"
                    text-anchor="middle"
                    font-size="8"
                    fill="var(--color-ink-dim)"
                    class="font-mono"
                  >
                    diverge
                  </text>
                  <text
                    x="110"
                    y="64"
                    text-anchor="middle"
                    font-size="8"
                    fill="var(--color-ink-dim)"
                    class="font-mono"
                  >
                    develop
                  </text>
                  <text
                    x="190"
                    y="64"
                    text-anchor="middle"
                    font-size="8"
                    fill="var(--color-ink-dim)"
                    class="font-mono"
                  >
                    critique
                  </text>
                  <text
                    x="270"
                    y="64"
                    text-anchor="middle"
                    font-size="8"
                    fill="var(--color-ink-dim)"
                    class="font-mono"
                  >
                    synthesize
                  </text>
                </svg>
                <p class="font-body text-[12px] text-ink-dim mt-2 max-w-sm">
                  Each iteration branches the top-scoring frontier nodes, then a critique trims the weak ones. After {@policy.ideate.default_budget_minutes} min the tree collapses to SYNTHESIS.md.
                </p>
              </div>

              <div>
                <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-2">
                  Try a sample idea
                </h2>
                <div class="flex flex-wrap gap-2">
                  <button
                    :for={seed <- sample_seeds()}
                    type="button"
                    phx-click="fill_seed"
                    phx-value-seed={seed}
                    class="font-body text-[12px] text-ink border border-surface-2 rounded-sm px-2.5 py-1.5 hover:bg-surface hover:border-accent text-left"
                  >
                    {seed}
                  </button>
                </div>
              </div>
            </div>

            <div :if={@session} class="md:flex-1 md:min-h-0 md:flex md:flex-col">
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

              <div class="grid xl:grid-cols-3 gap-4 md:flex-1 md:min-h-0 md:auto-rows-fr">
                <div class="xl:col-span-2 rounded-sm bg-surface border border-surface-2 overflow-hidden max-h-[60vh] md:max-h-none md:min-h-0 relative">
                  <span class="absolute top-2 right-3 font-mono text-[9px] text-ink-dim/50 select-none pointer-events-none">
                    scroll to zoom · drag to pan · dbl-click resets
                  </span>
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".TreeZoom">
                    // Wheel zooms at the cursor, drag pans, double-click resets.
                    // The user's viewport survives live tree updates; reset uses the
                    // server's current viewBox (data-viewbox), so it tracks growth.
                    export default {
                      mounted() {
                        this.dirty = false
                        this.dragging = null
                        const svg = this.el

                        svg.addEventListener("wheel", e => {
                          e.preventDefault()
                          const vb = this.viewBox()
                          // proportional to scroll delta: gentle per trackpad tick,
                          // ~9%/notch on a mouse wheel; clamped to 1/8x–4x of fit
                          let factor = Math.exp(e.deltaY * 0.00075)
                          const server = svg.dataset.viewbox.split(" ").map(Number)
                          const w = Math.min(Math.max(vb.w * factor, server[2] / 8), server[2] * 4)
                          factor = w / vb.w
                          const rect = svg.getBoundingClientRect()
                          const px = vb.x + ((e.clientX - rect.x) / rect.width) * vb.w
                          const py = vb.y + ((e.clientY - rect.y) / rect.height) * vb.h
                          this.setViewBox(px - ((px - vb.x) * factor), py - ((py - vb.y) * factor), w, vb.h * factor)
                        }, {passive: false})

                        svg.addEventListener("pointerdown", e => {
                          // NO capture here: a captured pointer retargets the click
                          // to the svg, which kills phx-click on the node circles
                          this.dragging = {x: e.clientX, y: e.clientY, id: e.pointerId, moved: false}
                        })
                        svg.addEventListener("pointermove", e => {
                          if (!this.dragging) return
                          const dx = e.clientX - this.dragging.x, dy = e.clientY - this.dragging.y
                          if (!this.dragging.moved && Math.abs(dx) + Math.abs(dy) > 4) {
                            this.dragging.moved = true
                            svg.setPointerCapture(this.dragging.id)
                          }
                          if (!this.dragging.moved) return
                          const vb = this.viewBox()
                          const rect = svg.getBoundingClientRect()
                          this.setViewBox(vb.x - dx * (vb.w / rect.width), vb.y - dy * (vb.h / rect.height), vb.w, vb.h)
                          this.dragging.x = e.clientX
                          this.dragging.y = e.clientY
                        })
                        svg.addEventListener("pointerup", e => {
                          if (this.dragging?.moved) {
                            // swallow the click that follows a drag so nodes don't open
                            svg.addEventListener("click", ev => ev.stopPropagation(), {capture: true, once: true})
                          }
                          this.dragging = null
                        })
                        svg.addEventListener("dblclick", () => {
                          this.dirty = false
                          svg.setAttribute("viewBox", svg.dataset.viewbox)
                        })
                      },
                      updated() {
                        if (this.dirty) this.el.setAttribute("viewBox", this.userViewBox)
                      },
                      viewBox() {
                        const [x, y, w, h] = this.el.getAttribute("viewBox").split(" ").map(Number)
                        return {x, y, w, h}
                      },
                      setViewBox(x, y, w, h) {
                        this.userViewBox = `${x} ${y} ${w} ${h}`
                        this.dirty = true
                        this.el.setAttribute("viewBox", this.userViewBox)
                      }
                    }
                  </script>
                  <svg
                    id="idea-tree"
                    phx-hook=".TreeZoom"
                    data-viewbox={"0 0 #{@tree_layout.width} #{@tree_layout.height}"}
                    viewBox={"0 0 #{@tree_layout.width} #{@tree_layout.height}"}
                    class="w-full cursor-grab active:cursor-grabbing touch-none select-none"
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

                <div class="rounded-sm bg-surface border border-surface-2 p-3 max-h-[60vh] md:max-h-none md:min-h-0 overflow-auto">
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
                    <p class="font-body text-[13px] text-ink-dim mb-2">
                      {@selected_node.idea.summary}
                    </p>
                    <div :if={@selected_node.artifact}>
                      <button
                        phx-click="select_node"
                        phx-value-id={@selected_node.idea.id}
                        class="font-display uppercase text-[10px] tracking-widest px-2 py-1 mb-2 border border-surface-2 text-ink-dim rounded-sm hover:border-accent hover:text-accent"
                      >
                        Expand
                      </button>
                      <div class="artifact-prose">{artifact_html(@selected_node.artifact)}</div>
                    </div>
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
      </div>

      <div
        :if={@artifact_open && @selected_node && @selected_node.artifact}
        id="artifact-modal"
        phx-window-keydown="close_artifact"
        phx-key="escape"
        class="fixed inset-0 z-50 flex items-center justify-center p-6"
        aria-modal="true"
        role="dialog"
      >
        <div class="absolute inset-0 bg-bg/85" phx-click="close_artifact" aria-hidden="true"></div>
        <div class="relative w-full max-w-3xl max-h-[72vh] flex flex-col rounded-sm bg-surface border border-surface-2 shadow-2xl">
          <div class="flex items-center gap-3 px-5 py-3 border-b border-surface-2 shrink-0">
            <span class="font-display text-sm text-ink">{@selected_node.idea.title}</span>
            <span class="font-mono text-[10px] text-ink-dim tabular-nums">
              score {@selected_node.idea.score} · d{@selected_node.idea.depth} · {@selected_node.idea.status}
            </span>
            <button
              phx-click="close_artifact"
              aria-label="close"
              class="ml-auto font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-alert hover:text-alert"
            >
              Close
            </button>
          </div>
          <div class="artifact-prose overflow-y-auto px-5 py-4 min-h-0">
            {artifact_html(@selected_node.artifact)}
          </div>
        </div>
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

  defp sample_seeds do
    [
      "A smarter PR triage that learns from past false positives",
      "Daily cost summaries pushed to mobile when the budget crosses 50%",
      "Adaptive ideation windows that shift based on rolling utilization"
    ]
  end
end
