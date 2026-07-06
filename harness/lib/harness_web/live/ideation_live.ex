defmodule HarnessWeb.IdeationLive do
  @moduledoc """
  Ideation view (spec §12.4): session list, a collapsible depth-indented
  outline of the idea tree (node color by score, pruned branches dimmed not
  hidden — see `Harness.Ideation.Outline` for the design rationale), a
  click-to-read artifact side panel, and a start-session form. Session
  vitals fold in the nudge box (with its own history) and a rolling feed of
  journal entries, replacing the separate floating nudge input and journal
  panel.
  """

  use HarnessWeb, :live_view

  alias Harness.Attachments
  alias Harness.Ideation
  alias Harness.Ideation.Outline
  alias Harness.Policy

  require Logger

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
     |> assign(:active_node_id, nil)
     |> assign(:critique_running, false)
     |> assign(:policy, policy)
     |> assign(:window_note, Policy.window_note(policy: policy, now: now))
     |> assign(:budget_minutes, budget)
     |> assign(:top_nodes, [])
     |> assign(:tokens_in, 0)
     |> assign(:tokens_out, 0)
     |> assign(:synthesis_open, false)
     |> assign(:synthesis_content, nil)
     |> assign(:search_query, "")
     |> assign(:promote_open, false)
     |> assign(:promote_node_id, nil)
     |> assign(:form, to_form(%{"seed_prompt" => "", "budget_minutes" => "#{budget}"}))
     |> allow_upload(:attachments, Attachments.upload_opts())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["id"] do
      nil ->
        {:noreply,
         assign(socket,
           session: nil,
           outline: [],
           ideas: [],
           journal: nil,
           selected_node: nil,
           top_nodes: [],
           tokens_in: 0,
           tokens_out: 0,
           synthesis_open: false,
           synthesis_content: nil,
           promote_open: false,
           promote_node_id: nil,
           search_query: ""
         )}

      id ->
        # navigating to a session starts with no artifact open
        if connected?(socket), do: Ideation.subscribe(String.to_integer(id))

        {:noreply,
         socket
         |> assign(:selected_node, nil)
         |> assign(:artifact_open, false)
         |> assign(:active_node_id, nil)
         |> assign(:critique_running, false)
         |> assign(:synthesis_open, false)
         |> assign(:synthesis_content, nil)
         |> assign(:promote_open, false)
         |> assign(:promote_node_id, nil)
         |> assign(:search_query, "")
         |> load_session(String.to_integer(id))}
    end
  end

  # does NOT touch :selected_node, so a live tree update preserves the
  # operator's open artifact panel
  defp load_session(socket, id) do
    session = Ideation.get_session!(id)
    ideas = Ideation.tree(id)
    journal = Ideation.read_journal(session)
    {tin, tout} = Ideation.token_totals(id)

    socket
    |> assign(:session, session)
    |> assign(:outline, Outline.build(ideas))
    |> assign(:ideas, ideas)
    |> assign(:journal, journal)
    |> assign(:top_nodes, Ideation.top_nodes(id))
    |> assign(:tokens_in, tin)
    |> assign(:tokens_out, tout)
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

      {session, _root} =
        Ideation.start_session(
          %{seed_prompt: seed, budget_minutes: budget},
          &persist_attachments(socket, &1)
        )

      {:noreply,
       socket
       |> assign(:form, to_form(%{"seed_prompt" => "", "budget_minutes" => to_string(budget)}))
       |> push_patch(to: ~p"/ideation/#{session.id}")}
    end
  end

  def handle_event("cancel_attachment", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  def handle_event("select_node", %{"id" => id}, socket) do
    idea = Ideation.get_idea!(String.to_integer(id))
    artifact = Ideation.read_artifact(idea)
    chain = Ideation.ancestor_chain(idea)
    ancestors = Enum.drop(chain, -1)
    children = Ideation.children(idea)
    siblings = Ideation.siblings(idea)
    sibling_index = Enum.find_index(siblings, &(&1.id == idea.id)) || 0

    {:noreply,
     socket
     |> assign(:selected_node, %{
       idea: idea,
       artifact: artifact,
       ancestors: ancestors,
       children: children,
       siblings: siblings,
       sibling_index: sibling_index
     })
     |> assign(:artifact_open, artifact != nil)}
  end

  def handle_event("close_artifact", _params, socket) do
    {:noreply, assign(socket, :artifact_open, false)}
  end

  def handle_event("modal_keydown", %{"key" => key}, socket) do
    case String.downcase(key) do
      "escape" ->
        {:noreply, assign(socket, artifact_open: false, synthesis_open: false)}

      "arrowleft" ->
        navigate_sibling(socket, -1)

      "arrowright" ->
        navigate_sibling(socket, +1)

      _ ->
        {:noreply, socket}
    end
  end

  defp navigate_sibling(%{assigns: %{selected_node: nil}} = socket, _dir),
    do: {:noreply, socket}

  defp navigate_sibling(%{assigns: %{selected_node: %{siblings: []}}} = socket, _dir),
    do: {:noreply, socket}

  defp navigate_sibling(socket, dir) do
    %{siblings: siblings, sibling_index: idx} = socket.assigns.selected_node
    new_idx = Integer.mod(idx + dir, length(siblings))
    sibling = Enum.at(siblings, new_idx)
    handle_event("select_node", %{"id" => to_string(sibling.id)}, socket)
  end

  def handle_event("tree_search", %{"q" => q}, socket) do
    {:noreply, assign(socket, :search_query, String.trim(q))}
  end

  def handle_event("stop_session", %{"id" => id}, socket) do
    id |> String.to_integer() |> Ideation.get_session!() |> Ideation.stop_session!(:operator)
    {:noreply, put_flash(socket, :info, "Session stopping after the current iteration.")}
  end

  def handle_event("synthesize_now", %{"id" => id}, socket) do
    id
    |> String.to_integer()
    |> Ideation.get_session!()
    |> Ideation.stop_session!(:operator_synthesis)

    {:noreply, put_flash(socket, :info, "Synthesis running — SYNTHESIS.md will open when ready.")}
  end

  def handle_event("submit_nudge", %{"session_id" => id, "nudge" => nudge}, socket) do
    nudge = String.trim(nudge)

    if nudge == "" do
      {:noreply, socket}
    else
      session = id |> String.to_integer() |> Ideation.get_session!()
      Ideation.set_nudge!(session, nudge)
      Ideation.append_journal!(session, session.iterations, ["nudge: " <> nudge])

      {:noreply,
       socket
       |> assign(:journal, Ideation.read_journal(session))
       |> put_flash(:info, "Nudge stored — next iteration will address it.")}
    end
  end

  def handle_event("focus_node", %{"id" => id}, socket) do
    node_id = String.to_integer(id)
    Ideation.set_forced_node!(socket.assigns.session, node_id)
    {:noreply, put_flash(socket, :info, "Next iteration will develop this branch.")}
  end

  def handle_event("open_synthesis", _params, socket) do
    content =
      case File.read(Ideation.synthesis_path(socket.assigns.session)) do
        {:ok, text} ->
          text

        {:error, reason} ->
          Logger.warning(
            "SYNTHESIS.md missing for session #{socket.assigns.session.id}: #{inspect(reason)}"
          )

          :missing
      end

    {:noreply, socket |> assign(:synthesis_open, true) |> assign(:synthesis_content, content)}
  end

  def handle_event("close_synthesis", _params, socket) do
    {:noreply, assign(socket, synthesis_open: false, synthesis_content: nil)}
  end

  def handle_event("synthesis_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, :synthesis_open, false)}
  end

  def handle_event("synthesis_keydown", _params, socket), do: {:noreply, socket}

  def handle_event("open_promote", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:promote_open, true)
     |> assign(:promote_node_id, String.to_integer(id))}
  end

  def handle_event("close_promote", _params, socket) do
    {:noreply, socket |> assign(:promote_open, false) |> assign(:promote_node_id, nil)}
  end

  def handle_event("confirm_promote", %{"target_repo" => target_repo}, socket) do
    policy = socket.assigns.policy

    if target_repo == "" or not Enum.any?(policy.github.repos, &(&1.name == target_repo)) do
      {:noreply, put_flash(socket, :error, "Select a repo from the policy list.")}
    else
      node_id = socket.assigns.promote_node_id
      session_id = socket.assigns.session.id

      %{session_id: session_id, idea_id: node_id, target_repo: target_repo}
      |> Harness.Ideation.PromoteWorker.new()
      |> Oban.insert!()

      {:noreply,
       socket
       |> assign(:promote_open, false)
       |> assign(:promote_node_id, nil)
       |> put_flash(:info, "Promoting to #{target_repo} — check the runs console for progress.")}
    end
  end

  @impl true
  def handle_info({event, _}, socket)
      when event in [:session_started, :session_updated] do
    socket =
      socket
      |> assign(:sessions, Ideation.list_sessions())
      |> assign(:active_node_id, nil)
      |> assign(:critique_running, false)

    socket =
      if socket.assigns[:session],
        do: load_session(socket, socket.assigns.session.id),
        else: socket

    # Auto-open synthesis modal when an operator_synthesis run completes.
    socket =
      with %{status: "synthesized", stop_reason: "operator_synthesis"} <-
             socket.assigns[:session],
           false <- socket.assigns[:synthesis_open] do
        assign(socket, :synthesis_open, true)
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_info({:developing_node, node_id}, socket) do
    {:noreply, socket |> assign(:active_node_id, node_id) |> assign(:critique_running, false)}
  end

  def handle_info({:critique_running, _session_id}, socket) do
    {:noreply, socket |> assign(:active_node_id, nil) |> assign(:critique_running, true)}
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

  defp persist_attachments(socket, dir) do
    Attachments.persist_uploaded_entries(socket, :attachments, dir)
  end

  # Past nudges, newest-first — parsed from the journal text `submit_nudge`
  # writes ("- nudge: ..." lines), so the operator can see what was asked for
  # instead of it vanishing after submit (issue #70).
  defp nudge_history(journal) when is_binary(journal) do
    ~r/^- nudge: (.+)$/m
    |> Regex.scan(journal)
    |> Enum.map(fn [_, text] -> text end)
    |> Enum.reverse()
  end

  defp nudge_history(_), do: []

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

  # Parse journal text into [{iteration_number, safe_html}] newest-first.
  # Each entry body is rendered via Earmark and node-title occurrences are
  # replaced with phx-click buttons so they select the node in the tree.
  defp journal_entries(journal, nodes) when is_binary(journal) do
    journal
    |> String.split(~r/(?=## Iteration \d+)/, trim: true)
    |> Enum.flat_map(fn part ->
      case Regex.run(~r/\A## Iteration (\d+)\s*\n(.*)\z/s, String.trim(part)) do
        [_, num_str, body] ->
          [{String.to_integer(num_str), journal_body_html(body, nodes)}]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(fn {num, _} -> num end, :desc)
  end

  defp journal_entries(_, _), do: []

  defp journal_body_html(markdown, nodes) do
    html =
      case Earmark.as_html(markdown) do
        {:ok, h, _} -> h
        {:error, h, _} -> h
      end

    # Sort longest titles first so "Advanced Feature X" matches before "Feature X"
    nodes
    |> Enum.sort_by(fn n -> -byte_size(n.title) end)
    |> Enum.reduce(html, fn node, acc ->
      escaped = node.title |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

      link =
        ~s|<button phx-click="select_node" phx-value-id="#{node.id}" | <>
          ~s|class="journal-node-link text-accent hover:underline cursor-pointer">| <>
          escaped <>
          "</button>"

      String.replace(acc, escaped, link)
    end)
    |> Phoenix.HTML.raw()
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
                  class="flex-1 min-w-0 accent-accent"
                />
                <span class="font-mono text-[11px] text-ink-dim tabular-nums w-14 text-right">
                  {@budget_minutes} min
                </span>
              </div>
              <div>
                <label class="font-mono text-[10px] text-ink-dim block mb-1">
                  Attachments (optional)
                </label>
                <.attachment_dropzone upload={@uploads.attachments} />
              </div>
              <div class="flex justify-end">
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
                  <span
                    :if={s.status == "synthesized"}
                    class="font-mono text-[9px] text-ok border border-ok/40 rounded px-1 shrink-0"
                  >doc</span>
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
              <div class="flex items-center gap-3 mb-1">
                <h1 class="font-display uppercase tracking-[0.16em] text-sm text-ink-dim">
                  Session #{@session.id}
                </h1>
                <span class={session_status_class(@session.status)}>{@session.status}</span>
                <span :if={@session.stop_reason} class="font-mono text-[10px] text-ink-dim">
                  {String.replace(@session.stop_reason, "_", " ")}
                </span>
                <div class="ml-auto flex items-center gap-2">
                  <button
                    :if={@session.status == "synthesized" && @session.synthesis_path}
                    phx-click="open_synthesis"
                    class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-ok text-ok rounded-sm hover:bg-ok/10"
                  >
                    Open synthesis
                  </button>
                  <.link
                    :if={@session.status == "synthesized" && @session.synthesis_path}
                    href={~p"/ideation/#{@session.id}/synthesis.md"}
                    download
                    class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-ok text-ok rounded-sm hover:bg-ok/10"
                  >
                    Download
                  </.link>
                  <.link
                    href={~p"/ideation/#{@session.id}/export.zip"}
                    download
                    class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-accent hover:text-accent"
                  >
                    Download all
                  </.link>
                  <button
                    :if={@session.status == "running"}
                    phx-click="synthesize_now"
                    phx-value-id={@session.id}
                    data-confirm="Run final synthesis over the current tree now?"
                    class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-ok text-ok rounded-sm hover:bg-ok/10"
                  >
                    Synthesize
                  </button>
                  <button
                    :if={@session.status == "running"}
                    phx-click="stop_session"
                    phx-value-id={@session.id}
                    data-confirm="Stop this ideation session?"
                    class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-alert text-alert rounded-sm hover:bg-alert hover:text-ink"
                  >
                    Stop
                  </button>
                </div>
              </div>
              <div class="flex items-center gap-3 mb-3">
                <span class="font-mono text-[10px] text-ink-dim tabular-nums">
                  {status_line(@session, @policy)}
                </span>
                <span
                  :if={@critique_running}
                  class="font-mono text-[10px] text-ink-dim/70 italic"
                >
                  critique in progress
                </span>
              </div>
              <div class="grid xl:grid-cols-3 gap-4 md:flex-1 md:min-h-0 md:auto-rows-fr">
                <div class="xl:col-span-2 rounded-sm bg-surface border border-surface-2 flex flex-col max-h-[60vh] md:max-h-none md:min-h-0">
                  <div class="flex items-center gap-2 px-2 py-1.5 border-b border-surface-2 shrink-0">
                    <h3 class="font-display uppercase tracking-[0.14em] text-[10px] text-ink-dim">
                      Idea tree
                    </h3>
                    <form phx-change="tree_search" id="tree-search-form" class="ml-auto">
                      <input
                        id="tree-search"
                        type="search"
                        name="q"
                        value={@search_query}
                        placeholder="Search nodes…"
                        phx-debounce="150"
                        autocomplete="off"
                        class="bg-bg/70 border border-surface-2 rounded-sm px-2 py-0.5 font-mono text-[10px] text-ink placeholder:text-ink-dim/50 focus:outline-none focus:border-accent w-28"
                      />
                    </form>
                  </div>
                  <div id="idea-outline" class="flex-1 min-h-0 overflow-y-auto py-1">
                    <p :if={@outline == []} class="px-3 py-2 font-body text-sm text-ink-dim">
                      No nodes yet.
                    </p>
                    <.outline_node
                      :for={node <- @outline}
                      node={node}
                      depth={0}
                      active_node_id={@active_node_id}
                      selected_id={@selected_node && @selected_node.idea.id}
                      search_query={@search_query}
                    />
                  </div>
                </div>

                <div class="rounded-sm bg-surface border border-surface-2 p-3 max-h-[60vh] md:max-h-none md:min-h-0 overflow-auto">
                  <div :if={!@selected_node} id="inspector-cockpit" class="space-y-4">
                    <div
                      :if={@session.status == "synthesized" && @session.synthesis_path}
                      class="flex items-center gap-2"
                    >
                      <button
                        phx-click="open_synthesis"
                        class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-ok text-ok rounded-sm hover:bg-ok/10"
                      >
                        Open Synthesis
                      </button>
                      <.link
                        href={~p"/ideation/#{@session.id}/synthesis.md"}
                        download
                        class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-ok text-ok rounded-sm hover:bg-ok/10"
                      >
                        Download
                      </.link>
                    </div>
                    <div>
                      <h4 class="font-display uppercase tracking-[0.14em] text-[10px] text-ink-dim mb-1">
                        Vitals
                      </h4>
                      <p class="font-mono text-[11px] text-ink-dim tabular-nums">
                        {status_line(@session, @policy)}
                      </p>
                      <p class="font-mono text-[11px] text-ink-dim tabular-nums mt-0.5">
                        tokens {@tokens_in + @tokens_out} ({@tokens_in}↑ {@tokens_out}↓)
                      </p>

                      <div :if={Ideation.attachments(@session) != []} class="mt-2">
                        <h5 class="font-display uppercase tracking-[0.14em] text-[9px] text-ink-dim/70 mb-1">
                          Attachments
                        </h5>
                        <ul class="space-y-0.5">
                          <li :for={a <- Ideation.attachments(@session)}>
                            <.link
                              href={~p"/ideation/#{@session.id}/attachments/#{a["filename"]}"}
                              target="_blank"
                              class="font-mono text-[10px] text-accent hover:underline"
                            >
                              {a["filename"]}
                            </.link>
                          </li>
                        </ul>
                      </div>

                      <div :if={@session.status == "running"} class="mt-3">
                        <h5 class="font-display uppercase tracking-[0.14em] text-[9px] text-ink-dim/70 mb-1">
                          Nudge
                        </h5>
                        <ul
                          :if={nudge_history(@journal) != []}
                          class="space-y-0.5 mb-1.5 max-h-20 overflow-auto"
                        >
                          <li
                            :for={text <- nudge_history(@journal)}
                            class="font-mono text-[10px] text-ink-dim/70 truncate"
                          >
                            › {text}
                          </li>
                        </ul>
                        <form phx-submit="submit_nudge" class="flex gap-1.5">
                          <input type="hidden" name="session_id" value={@session.id} />
                          <input
                            name="nudge"
                            type="text"
                            placeholder="Nudge next iteration…"
                            autocomplete="off"
                            class="flex-1 min-w-0 bg-surface border border-surface-2 rounded-sm px-2 py-1 font-mono text-[11px] text-ink focus:outline-2 focus:outline-accent"
                          />
                          <button
                            type="submit"
                            class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-accent hover:text-accent shrink-0"
                          >
                            Nudge
                          </button>
                        </form>
                      </div>
                    </div>

                    <div>
                      <h4 class="font-display uppercase tracking-[0.14em] text-[10px] text-ink-dim mb-1">
                        Top nodes
                      </h4>
                      <p :if={@top_nodes == []} class="font-body text-[12px] text-ink-dim">
                        No nodes yet.
                      </p>
                      <button
                        :for={idea <- @top_nodes}
                        phx-click="select_node"
                        phx-value-id={idea.id}
                        class="flex items-center gap-2 w-full text-left px-2 py-1 rounded-sm hover:bg-bg"
                      >
                        <span class="font-mono text-[11px] tabular-nums text-ink-dim/70 w-8 text-right shrink-0">
                          {idea.score}
                        </span>
                        <span class="font-body text-[12px] text-ink truncate flex-1">
                          {idea.title}
                        </span>
                        <span class="font-mono text-[10px] text-ink-dim/50 shrink-0">
                          {idea.status}
                        </span>
                      </button>
                    </div>

                    <div>
                      <h4 class="font-display uppercase tracking-[0.14em] text-[10px] text-ink-dim mb-1">
                        Recent activity
                      </h4>
                      <p
                        :if={journal_entries(@journal, @ideas) == []}
                        class="font-body text-[12px] text-ink-dim"
                      >
                        No journal entries yet.
                      </p>
                      <div class="space-y-2 max-h-48 overflow-auto">
                        <div
                          :for={{num, html} <- journal_entries(@journal, @ideas)}
                          class="rounded-sm border border-surface-2 px-2 py-1.5"
                        >
                          <div class="font-mono text-[9px] text-ink-dim/60 uppercase tracking-wider mb-0.5">
                            Iteration {num}
                          </div>
                          <div class="artifact-prose text-[11px]">{html}</div>
                        </div>
                      </div>
                    </div>
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
                    <div class="flex gap-2 mb-2 flex-wrap">
                      <button
                        :if={@selected_node.artifact}
                        phx-click="select_node"
                        phx-value-id={@selected_node.idea.id}
                        class="font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-accent hover:text-accent"
                      >
                        Expand
                      </button>
                      <.link
                        :if={@selected_node.artifact}
                        href={~p"/ideation/nodes/#{@selected_node.idea.id}/artifact.md"}
                        download
                        class="font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-accent hover:text-accent"
                      >
                        Download
                      </.link>
                      <button
                        :if={
                          @session && @session.status == "running" &&
                            @selected_node.idea.status == "frontier"
                        }
                        phx-click="focus_node"
                        phx-value-id={@selected_node.idea.id}
                        class="font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-accent hover:text-accent"
                      >
                        Focus
                      </button>
                      <button
                        :if={promotable?(@selected_node.idea) && @policy.github.repos != []}
                        phx-click="open_promote"
                        phx-value-id={@selected_node.idea.id}
                        class="font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-ok text-ok rounded-sm hover:bg-ok/10"
                      >
                        Promote
                      </button>
                    </div>
                    <div
                      :if={@selected_node.idea.promoted_epic_url}
                      class="mb-2 font-mono text-[10px] text-ok"
                    >
                      epic:
                      <a
                        href={@selected_node.idea.promoted_epic_url}
                        target="_blank"
                        class="underline"
                      >{@selected_node.idea.promoted_epic_url}</a>
                    </div>
                    <div :if={@selected_node.artifact} class="artifact-prose">
                      {artifact_html(@selected_node.artifact)}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </section>
        </div>
      </div>

      <div
        :if={@artifact_open && @selected_node && @selected_node.artifact}
        id="artifact-modal"
        phx-window-keydown="modal_keydown"
        class="fixed inset-0 z-50 flex items-center justify-center p-6"
        aria-modal="true"
        role="dialog"
      >
        <div class="absolute inset-0 bg-bg/85" phx-click="close_artifact" aria-hidden="true"></div>
        <div class="relative w-full max-w-3xl max-h-[80vh] flex flex-col rounded-sm bg-surface border border-surface-2 shadow-2xl">
          <div
            :if={@selected_node.ancestors != []}
            class="flex items-center gap-1 flex-wrap px-5 py-2 border-b border-surface-2 shrink-0"
          >
            <span :for={anc <- @selected_node.ancestors} class="flex items-center gap-1">
              <button
                phx-click="select_node"
                phx-value-id={anc.id}
                class="font-mono text-[10px] text-ink-dim hover:text-accent"
              >
                {anc.title}
              </button>
              <span class="font-mono text-[10px] text-ink-dim/40">›</span>
            </span>
          </div>

          <div class="flex items-center gap-3 px-5 py-3 border-b border-surface-2 shrink-0">
            <span class="font-display text-sm text-ink">{@selected_node.idea.title}</span>
            <span class="font-mono text-[10px] text-ink-dim tabular-nums">
              score {@selected_node.idea.score} · d{@selected_node.idea.depth} · {@selected_node.idea.status}
            </span>
            <.link
              href={~p"/ideation/nodes/#{@selected_node.idea.id}/artifact.md"}
              download
              class="ml-auto font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-accent hover:text-accent"
            >
              Download
            </.link>
            <button
              phx-click="close_artifact"
              aria-label="close"
              class="font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-alert hover:text-alert"
            >
              Close
            </button>
          </div>

          <div class="artifact-prose overflow-y-auto px-5 py-4 min-h-0">
            {artifact_html(@selected_node.artifact)}
          </div>

          <div
            :if={@selected_node.children != []}
            class="border-t border-surface-2 px-5 py-3 shrink-0"
          >
            <h4 class="font-display uppercase tracking-[0.14em] text-[10px] text-ink-dim mb-2">
              Children
            </h4>
            <div class="flex flex-wrap gap-2">
              <button
                :for={child <- @selected_node.children}
                phx-click="select_node"
                phx-value-id={child.id}
                class="font-mono text-[10px] px-2 py-1 rounded-sm border border-surface-2 text-ink-dim hover:border-accent hover:text-accent"
              >
                {child.title} · {child.score}
              </button>
            </div>
          </div>
        </div>
      </div>
      <div
        :if={@synthesis_open && @session && @session.synthesis_path}
        id="synthesis-modal"
        phx-window-keydown="synthesis_keydown"
        class="fixed inset-0 z-50 flex items-center justify-center p-6"
        aria-modal="true"
        role="dialog"
      >
        <div
          class="absolute inset-0 bg-bg/85"
          phx-click="close_synthesis"
          aria-hidden="true"
        >
        </div>
        <div class="relative w-full max-w-3xl max-h-[80vh] flex flex-col rounded-sm bg-surface border border-surface-2 shadow-2xl">
          <div class="flex items-center gap-3 px-5 py-3 border-b border-surface-2 shrink-0">
            <span class="font-display text-sm text-ink">SYNTHESIS.md</span>
            <span class="font-mono text-[10px] text-ink-dim">session #{@session.id}</span>
            <.link
              :if={@synthesis_content != :missing}
              href={~p"/ideation/#{@session.id}/synthesis.md"}
              download
              class="ml-auto font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-accent hover:text-accent"
            >
              Download
            </.link>
            <button
              phx-click="close_synthesis"
              aria-label="close"
              class={[
                "font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-alert hover:text-alert",
                @synthesis_content == :missing && "ml-auto"
              ]}
            >
              Close
            </button>
          </div>
          <div class="artifact-prose overflow-y-auto px-5 py-4 min-h-0">
            <%= if @synthesis_content == :missing do %>
              <p class="font-body text-sm text-ink-dim">(synthesis file not found)</p>
            <% else %>
              {artifact_html(@synthesis_content || "")}
            <% end %>
          </div>
        </div>
      </div>
      <div
        :if={@promote_open && @promote_node_id}
        id="promote-modal"
        class="fixed inset-0 z-50 flex items-center justify-center p-6"
        aria-modal="true"
        role="dialog"
      >
        <div class="absolute inset-0 bg-bg/85" phx-click="close_promote" aria-hidden="true"></div>
        <div class="relative w-full max-w-md rounded-sm bg-surface border border-surface-2 shadow-2xl p-5">
          <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-3">
            Promote branch to GitHub issues
          </h2>
          <p class="font-body text-[12px] text-ink-dim mb-4">
            This will create one epic tracking issue and child implementation issues
            in the selected repository. All issues will be self-assigned so the
            harness triage picks them up.
          </p>
          <form phx-submit="confirm_promote" class="space-y-3">
            <div>
              <label class="font-mono text-[10px] text-ink-dim block mb-1">
                Target repository
              </label>
              <select
                name="target_repo"
                class="w-full bg-bg border border-surface-2 rounded-sm px-2 py-1.5 font-mono text-[11px] text-ink focus:outline-2 focus:outline-accent"
              >
                <option value="">— select —</option>
                <option :for={r <- @policy.github.repos} value={r.name}>{r.name}</option>
              </select>
            </div>
            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="close_promote"
                class="font-display uppercase text-[10px] tracking-widest px-3 py-1.5 border border-surface-2 text-ink-dim rounded-sm hover:border-accent"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="font-display uppercase text-[10px] tracking-widest px-3 py-1.5 bg-ok text-bg rounded-sm hover:opacity-90"
              >
                Promote
              </button>
            </div>
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # One row of the depth-indented idea outline (see `Harness.Ideation.Outline`
  # for why this replaced the pan/zoom SVG tree), plus its children, rendered
  # recursively. Branches with children get a caret that toggles visibility
  # client-side via `JS.toggle/1` — no server round-trip, no JS hook needed.
  # Pruned branches start collapsed; everything else starts open.
  attr :node, :map, required: true
  attr :depth, :integer, default: 0
  attr :active_node_id, :any, default: nil
  attr :selected_id, :any, default: nil
  attr :search_query, :string, default: ""

  defp outline_node(assigns) do
    ~H"""
    <div>
      <div
        class="flex items-center gap-1.5 px-2 py-1 hover:bg-bg"
        style={"padding-left: #{8 + min(@depth, 8) * 16}px"}
      >
        <button
          :if={@node.children != []}
          type="button"
          phx-click={Phoenix.LiveView.JS.toggle(to: "#outline-children-#{@node.idea.id}")}
          class="w-3 shrink-0 text-ink-dim/60 hover:text-accent select-none"
          aria-label="toggle branch"
        >
          ▸
        </button>
        <span :if={@node.children == []} class="w-3 shrink-0"></span>
        <div
          phx-click="select_node"
          phx-value-id={@node.idea.id}
          class="flex items-center gap-2 flex-1 min-w-0 cursor-pointer"
          style={"opacity: #{node_display_opacity(@search_query, @node.idea)}"}
          data-developing={if @active_node_id == @node.idea.id, do: "true"}
          data-match={node_match_attr(@search_query, @node.idea)}
        >
          <span
            class={[
              "w-2 h-2 rounded-full shrink-0",
              @active_node_id == @node.idea.id && "node-developing"
            ]}
            style={"background: #{score_fill(@node.idea.score)}"}
          ></span>
          <span class={[
            "font-body text-[12px] truncate",
            if(@selected_id == @node.idea.id, do: "text-accent", else: "text-ink")
          ]}>
            {@node.idea.title}
          </span>
          <span class="font-mono text-[10px] text-ink-dim/70 tabular-nums shrink-0">
            {score_text(@node.idea.score)}
          </span>
          <span class="font-mono text-[9px] text-ink-dim/50 shrink-0">{@node.idea.status}</span>
        </div>
      </div>
      <div
        :if={@node.children != []}
        id={"outline-children-#{@node.idea.id}"}
        class={@node.idea.status == "pruned" && "hidden"}
      >
        <.outline_node
          :for={child <- @node.children}
          node={child}
          depth={@depth + 1}
          active_node_id={@active_node_id}
          selected_id={@selected_id}
          search_query={@search_query}
        />
      </div>
    </div>
    """
  end

  defp status_line(session, policy) do
    used = DateTime.diff(DateTime.utc_now(), session.started_at, :second) |> div(60)
    used = used |> max(0) |> min(session.budget_minutes)
    total = session.budget_minutes
    bar = budget_bar(used, total)

    "iteration #{session.iterations} · critique #{session.critiques}/#{policy.ideate.critique_every} · budget #{bar} #{used}/#{total} min"
  end

  defp budget_bar(used, total, blocks \\ 6) do
    filled = if total > 0, do: round(used / total * blocks) |> min(blocks) |> max(0), else: 0
    String.duplicate("▓", filled) <> String.duplicate("░", blocks - filled)
  end

  defp node_matches?("", _), do: true

  defp node_matches?(query, node) do
    q = String.downcase(query)

    String.contains?(String.downcase(node.title), q) ||
      String.contains?(String.downcase(node.summary || ""), q)
  end

  defp node_match_attr("", _), do: nil
  defp node_match_attr(query, node), do: to_string(node_matches?(query, node))

  defp node_display_opacity("", node), do: if(node.status == "pruned", do: "0.3", else: "1")

  defp node_display_opacity(query, node) do
    if node_matches?(query, node) do
      if node.status == "pruned", do: "0.3", else: "1"
    else
      "0.15"
    end
  end

  defp score_text(nil), do: ""
  defp score_text(score), do: score |> Float.round(1) |> to_string()

  # score → color ramp: low = dim, high = accent (no red/green — those are
  # status colors)
  defp score_fill(score) when score >= 7.5, do: "var(--color-accent)"
  defp score_fill(score) when score >= 5.0, do: "#5f7487"
  defp score_fill(_), do: "var(--color-surface-2)"

  defp session_status_class("running"), do: "font-mono text-[10px] uppercase text-accent"
  defp session_status_class("synthesized"), do: "font-mono text-[10px] uppercase text-ok"
  defp session_status_class(_), do: "font-mono text-[10px] uppercase text-ink-dim"

  defp promotable?(%{score: score, status: status}) do
    score >= 7.0 or status == "synthesized"
  end

  defp sample_seeds do
    [
      "A smarter PR triage that learns from past false positives",
      "Daily cost summaries pushed to mobile when the budget crosses 50%",
      "Adaptive ideation windows that shift based on rolling utilization"
    ]
  end
end
