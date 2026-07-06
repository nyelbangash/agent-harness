defmodule HarnessWeb.IssuesLive do
  @moduledoc """
  The issue board (spec §12): Incoming → Triaged → In progress → Ready for
  review → Done · Failed. Re-queries the (small, single-user) board on each
  `{:issue_updated, _}` broadcast — LiveView diffing keeps the wire cheap.
  Columns stack into sections under the md breakpoint (phone via Tailscale).
  """

  use HarnessWeb, :live_view

  alias Harness.GitHub
  alias Harness.Runs

  @columns [
    {:incoming, "Incoming"},
    {:triaged, "Triaged"},
    {:in_progress, "In progress"},
    {:review, "Ready for review"},
    {:review_stalled, "Review stalled"},
    {:done, "Done · Failed"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      GitHub.subscribe()
      Runs.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Issues")
     |> assign(:columns, @columns)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:last_selected_id, nil)
     |> assign(:selected_issue, nil)
     |> assign(:issue_runs, [])
     |> load_board()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["id"] do
      nil ->
        {:noreply, socket |> assign(:selected_issue, nil) |> assign(:issue_runs, [])}

      id ->
        {:noreply, load_issue_detail(socket, String.to_integer(id))}
    end
  end

  defp load_issue_detail(socket, issue_id) do
    issue = GitHub.get_issue!(issue_id)

    socket
    |> assign(:selected_issue, issue)
    |> assign(:issue_runs, Runs.runs_for_issue(issue_id))
  end

  @impl true
  def handle_info({:issue_updated, issue}, socket) do
    socket = load_board(socket)

    socket =
      if socket.assigns.selected_issue && socket.assigns.selected_issue.id == issue.id do
        load_issue_detail(socket, issue.id)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:run_updated, run}, socket) do
    socket = load_board(socket)

    socket =
      if socket.assigns.selected_issue && run.issue_id == socket.assigns.selected_issue.id do
        assign(socket, :issue_runs, Runs.runs_for_issue(socket.assigns.selected_issue.id))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_card", %{"id" => id, "shift" => shift, "meta" => meta}, socket) do
    id = String.to_integer(id)

    socket =
      cond do
        shift -> select_range(socket, id)
        meta -> toggle_selected(socket, id)
        true -> select_only(socket, id)
      end

    {:noreply, socket}
  end

  def handle_event("trash_selected", _params, socket) do
    {:noreply, dismiss_and_clear_selection(socket, MapSet.to_list(socket.assigns.selected_ids))}
  end

  def handle_event("trash_drop", %{"ids" => ids}, socket) do
    {:noreply, dismiss_and_clear_selection(socket, Enum.map(ids, &String.to_integer/1))}
  end

  defp select_only(socket, id) do
    socket
    |> assign(:selected_ids, MapSet.new([id]))
    |> assign(:last_selected_id, id)
  end

  defp toggle_selected(socket, id) do
    selected = socket.assigns.selected_ids

    updated =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    socket
    |> assign(:selected_ids, updated)
    |> assign(:last_selected_id, id)
  end

  # contiguous range between the last-clicked card and `id`, within the
  # column that both belong to (per the column's current render order); falls
  # back to a plain single-card selection when there is no anchor yet or the
  # two cards live in different columns
  defp select_range(socket, id) do
    case socket.assigns.last_selected_id do
      nil ->
        select_only(socket, id)

      anchor_id ->
        case range_within_column(socket.assigns.board, anchor_id, id) do
          nil -> select_only(socket, id)
          ids -> assign(socket, :selected_ids, MapSet.new(ids))
        end
    end
  end

  defp range_within_column(board, anchor_id, id) do
    Enum.find_value(board, fn {_column, issues} ->
      column_ids = Enum.map(issues, & &1.id)

      if anchor_id in column_ids and id in column_ids do
        i = Enum.find_index(column_ids, &(&1 == anchor_id))
        j = Enum.find_index(column_ids, &(&1 == id))
        {lo, hi} = if i <= j, do: {i, j}, else: {j, i}
        Enum.slice(column_ids, lo..hi)
      end
    end)
  end

  defp dismiss_and_clear_selection(socket, []), do: socket

  defp dismiss_and_clear_selection(socket, ids) do
    GitHub.dismiss_issues!(ids)

    socket
    |> assign(:selected_ids, MapSet.new())
    |> assign(:last_selected_id, nil)
    |> put_flash(:info, "Dismissed #{length(ids)} issue(s)")
  end

  defp load_board(socket) do
    board = GitHub.board()
    visible_ids = board |> Map.values() |> List.flatten() |> MapSet.new(& &1.id)

    socket
    |> assign(:board, board)
    |> assign(:empty?, board == %{})
    |> assign(:selected_ids, MapSet.intersection(socket.assigns.selected_ids, visible_ids))
    |> attach_triages(board)
    |> attach_run_errors(board)
    |> attach_run_phases(board)
  end

  # confidence/route chips come from the latest triage per issue
  defp attach_triages(socket, board) do
    triages =
      board
      |> Map.values()
      |> List.flatten()
      |> Map.new(fn issue -> {issue.id, GitHub.latest_triage(issue.id)} end)

    assign(socket, :triages, triages)
  end

  # failure reason badges come from the latest terminal run for failed issues
  defp attach_run_errors(socket, board) do
    run_errors =
      Map.get(board, :done, [])
      |> Enum.filter(&(&1.pipeline_state == "failed"))
      |> Map.new(fn issue -> {issue.id, Runs.latest_terminal_run_error(issue.id)} end)

    assign(socket, :run_errors, run_errors)
  end

  # phase chips come from any active implement run for in-progress issues
  defp attach_run_phases(socket, board) do
    phases =
      Map.get(board, :in_progress, [])
      |> Map.new(fn issue -> {issue.id, Runs.active_implement_status(issue.id)} end)

    assign(socket, :run_phases, phases)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      mode={@mode}
      usage_mode={@usage_mode}
      usage_health={@usage_health}
    >
      <div class="page-fit md:flex md:flex-col md:min-h-0 md:overflow-hidden">
        <h1 class="font-display uppercase tracking-[0.16em] text-sm text-ink-dim mb-6">
          Issue board
        </h1>

        <p :if={@empty?} class="font-body text-sm text-ink-dim">
          No issues yet — add a repo to <span class="font-mono">ops/policy.yaml → github.repos</span>
          and assign yourself an issue. The poller checks every 2 minutes.
        </p>

        <div :if={!@empty?} class="flex items-center gap-2 mb-3">
          <button
            :if={MapSet.size(@selected_ids) > 0}
            phx-click="trash_selected"
            data-testid="trash-selected"
            class="font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-alert text-alert rounded-sm hover:bg-alert hover:text-bg flex items-center gap-1"
          >
            <.icon name="hero-trash" class="size-3.5" /> Trash selected ({MapSet.size(@selected_ids)})
          </button>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".SelectableCard">
            export default {
              mounted() {
                this.el.addEventListener("click", e => {
                  if (e.target.closest("a, button")) return
                  this.pushEvent("select_card", {
                    id: this.el.dataset.issueId,
                    shift: e.shiftKey,
                    meta: e.metaKey || e.ctrlKey
                  })
                })
                this.el.addEventListener("dragstart", e => {
                  const board = document.getElementById("issue-board")
                  const selected = (board?.dataset.selectedIds || "").split(",").filter(Boolean)
                  const id = this.el.dataset.issueId
                  const ids = selected.includes(id) ? selected : [id]
                  e.dataTransfer.effectAllowed = "move"
                  e.dataTransfer.setData("text/plain", JSON.stringify({ids}))
                })
              }
            }
          </script>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".TrashTarget">
            export default {
              mounted() {
                this.el.addEventListener("dragover", e => e.preventDefault())
                this.el.addEventListener("drop", e => {
                  e.preventDefault()
                  const raw = e.dataTransfer.getData("text/plain")
                  if (!raw) return
                  const {ids} = JSON.parse(raw)
                  this.pushEvent("trash_drop", {ids})
                })
              }
            }
          </script>
          <div
            id="board-trash-target"
            phx-hook=".TrashTarget"
            data-testid="trash-target"
            class="ml-auto font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-dashed border-ink-dim/40 text-ink-dim rounded-sm flex items-center gap-1"
          >
            <.icon name="hero-trash" class="size-3.5" /> Drop to trash
          </div>
        </div>

        <div
          :if={!@empty?}
          id="issue-board"
          data-selected-ids={Enum.join(@selected_ids, ",")}
          class="grid md:grid-cols-3 xl:grid-cols-6 gap-4 md:flex-1 md:min-h-0 md:auto-rows-fr"
        >
          <section
            :for={{key, title} <- @columns}
            aria-label={title}
            data-column={key}
            class="md:flex md:flex-col md:min-h-0"
          >
            <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-2 flex items-center gap-2">
              {title}
              <span class="font-mono tabular-nums text-[10px] px-1.5 rounded-sm bg-surface-2 text-ink-dim">
                {length(Map.get(@board, key, []))}
              </span>
            </h2>
            <div class="space-y-2 md:flex-1 md:min-h-0 md:overflow-y-auto">
              <.issue_card
                :for={issue <- Map.get(@board, key, [])}
                issue={issue}
                triage={@triages[issue.id]}
                run_error={@run_errors[issue.id]}
                phase_status={Map.get(@run_phases, issue.id)}
                selected={MapSet.member?(@selected_ids, issue.id)}
              />
            </div>
          </section>
        </div>
      </div>

      <.issue_detail_modal
        :if={@selected_issue}
        issue={@selected_issue}
        runs={@issue_runs}
      />
    </Layouts.app>
    """
  end

  attr :issue, :map, required: true
  attr :runs, :list, required: true

  defp issue_detail_modal(assigns) do
    ~H"""
    <div
      id="issue-detail-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-6"
      aria-modal="true"
      role="dialog"
      data-testid="issue-detail-modal"
    >
      <.link
        patch={~p"/issues"}
        class="absolute inset-0 bg-bg/85"
        aria-hidden="true"
      ></.link>
      <div class="relative w-full max-w-2xl max-h-[85vh] flex flex-col rounded-sm bg-surface border border-surface-2 shadow-2xl">
        <div class="flex items-center gap-3 px-5 py-3 border-b border-surface-2 shrink-0">
          <span class="font-mono text-[11px] text-accent tabular-nums">
            {@issue.repo}#{@issue.number}
          </span>
          <span class="font-display text-sm text-ink truncate flex-1">{@issue.title}</span>
          <span class="font-mono text-[10px] text-ink-dim uppercase shrink-0">
            {@issue.pipeline_state}
          </span>
          <.link
            patch={~p"/issues"}
            aria-label="close"
            class="font-display uppercase text-[10px] tracking-widest px-2 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-alert hover:text-alert shrink-0"
          >
            Close
          </.link>
        </div>

        <div class="overflow-y-auto px-5 py-4 space-y-4 min-h-0">
          <div class="flex items-center gap-2 flex-wrap">
            <a
              href={@issue.url}
              target="_blank"
              rel="noopener"
              class="font-mono text-[10px] text-accent hover:underline"
            >
              View on GitHub ↗
            </a>
            <a
              :if={@issue.pr_url}
              href={@issue.pr_url}
              target="_blank"
              rel="noopener"
              class="font-mono text-[10px] text-accent hover:underline"
            >
              PR #{@issue.pr_number} ↗
            </a>
          </div>

          <div class="flex items-center gap-2 flex-wrap">
            <button
              :if={@issue.pr_number}
              phx-click="enqueue_review"
              phx-value-id={@issue.id}
              class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-accent text-accent rounded-sm hover:bg-accent/10"
            >
              Adversarial review
            </button>
            <button
              :if={@issue.pr_number}
              phx-click="enqueue_bug_hunt"
              phx-value-id={@issue.id}
              class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-accent hover:text-accent"
            >
              Bug-hunt pass
            </button>
            <button
              :if={@issue.pr_number}
              phx-click="enqueue_format"
              phx-value-id={@issue.id}
              class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-accent hover:text-accent"
            >
              Format pass
            </button>
            <span :if={!@issue.pr_number} class="font-mono text-[10px] text-ink-dim">
              no open PR — actions unlock once one exists
            </span>
          </div>

          <div>
            <h3 class="font-display uppercase tracking-[0.14em] text-[10px] text-ink-dim mb-2">
              Run history
            </h3>
            <p :if={@runs == []} class="font-body text-sm text-ink-dim">No runs yet.</p>
            <ul :if={@runs != []} class="space-y-1">
              <li
                :for={run <- @runs}
                class="flex items-center gap-2 text-[12px]"
                data-testid="issue-run-row"
              >
                <.link
                  navigate={~p"/runs/#{run.id}"}
                  class="font-mono text-[10px] text-accent hover:underline tabular-nums"
                >
                  #{run.id}
                </.link>
                <span class="font-mono text-[10px] text-ink-dim uppercase">{run.kind}</span>
                <span class={run_status_class(run.status)}>{run.status}</span>
              </li>
            </ul>
          </div>

          <div>
            <h3 class="font-display uppercase tracking-[0.14em] text-[10px] text-ink-dim mb-2">
              Thread
            </h3>
            <form phx-submit="post_thread_comment" class="flex gap-1.5">
              <input type="hidden" name="issue_id" value={@issue.id} />
              <input
                name="body"
                type="text"
                placeholder="Post a comment/request — reaches GitHub and the harness"
                autocomplete="off"
                class="flex-1 min-w-0 bg-bg border border-surface-2 rounded-sm px-2 py-1 font-mono text-[11px] text-ink focus:outline-2 focus:outline-accent"
              />
              <button
                type="submit"
                class="font-display uppercase text-[10px] tracking-widest px-2.5 py-1 border border-surface-2 text-ink-dim rounded-sm hover:border-accent hover:text-accent shrink-0"
              >
                Post
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp run_status_class("succeeded"), do: "font-mono text-[10px] uppercase text-ok"

  defp run_status_class(status) when status in ~w(failed killed),
    do: "font-mono text-[10px] uppercase text-alert"

  defp run_status_class(_), do: "font-mono text-[10px] uppercase text-ink-dim"

  attr :issue, :map, required: true
  attr :triage, :map, default: nil
  attr :run_error, :string, default: nil
  attr :phase_status, :string, default: nil
  attr :selected, :boolean, default: false

  defp issue_card(assigns) do
    ~H"""
    <article
      id={"issue-card-#{@issue.id}"}
      phx-hook=".SelectableCard"
      draggable="true"
      data-issue-id={@issue.id}
      class={[
        "rounded-sm bg-surface border px-3 py-2.5 cursor-pointer select-none",
        if(@issue.pipeline_state == "failed", do: "border-alert/60", else: "border-surface-2"),
        @selected && "ring-2 ring-accent"
      ]}
      data-testid="issue-card"
      data-issue-number={@issue.number}
      data-selected={@selected}
    >
      <div class="flex items-center gap-2 mb-1">
        <a
          href={@issue.url}
          target="_blank"
          rel="noopener"
          class="font-mono text-[11px] text-accent tabular-nums hover:underline"
        >
          {@issue.repo}#{@issue.number}
        </a>
        <span
          :if={@issue.pipeline_state == "failed"}
          class="font-display uppercase text-[9px] tracking-widest px-1 py-0.5 bg-alert/20 text-alert rounded-sm"
        >
          failed
        </span>
        <span
          :if={@issue.pipeline_state == "failed" and run_reason_badge(@run_error)}
          class="font-display uppercase text-[9px] tracking-widest text-alert/70"
        >{run_reason_badge(@run_error)}</span>
        <span
          :if={@issue.pipeline_state == "skipped"}
          class="font-display uppercase text-[9px] tracking-widest px-1 py-0.5 bg-surface-2 text-ink-dim rounded-sm"
        >
          skipped
        </span>
        <span
          :if={@issue.pipeline_state == "done"}
          class="font-display uppercase text-[9px] tracking-widest px-1 py-0.5 bg-ok/20 text-ok rounded-sm"
        >
          done
        </span>
        <span
          :if={"agent-cloud" in @issue.labels}
          class="font-display uppercase text-[9px] tracking-widest px-1 py-0.5 bg-accent/10 text-accent rounded-sm"
          title="Handled by the off-machine GitHub Action lane"
        >
          ☁ cloud
        </span>
        <span
          :if={phase_label(@phase_status)}
          class="font-display uppercase text-[9px] tracking-widest px-1 py-0.5 bg-accent/20 text-accent rounded-sm animate-pulse"
        >
          {phase_label(@phase_status)}
        </span>
      </div>

      <.link
        patch={~p"/issues/#{@issue.id}"}
        class="block font-body text-[13px] leading-snug text-ink mb-1.5 hover:text-accent"
      >
        {@issue.title}
      </.link>

      <div :if={@issue.pr_url} class="mb-1.5">
        <a
          href={@issue.pr_url}
          target="_blank"
          rel="noopener"
          class="font-mono text-[10px] text-accent hover:underline"
        >
          PR #{@issue.pr_number} ↗
        </a>
      </div>

      <div :if={@triage} class="flex items-center gap-1.5 flex-wrap">
        <span class={[
          "font-display uppercase text-[9px] tracking-widest px-1.5 py-0.5 rounded-sm",
          route_chip(@triage.final_route)
        ]}>
          {@triage.final_route}
        </span>
        <span :if={@triage.confidence} class="font-mono text-[10px] text-ink-dim tabular-nums">
          {:erlang.float_to_binary(@triage.confidence, decimals: 2)}
        </span>
        <span :if={@triage.estimated_scope} class="font-mono text-[10px] text-ink-dim uppercase">
          {@triage.estimated_scope}
        </span>
        <span
          :for={flag <- @triage.risk_flags || []}
          class="font-mono text-[9px] text-ink-dim px-1 bg-surface-2 rounded-sm"
        >
          {flag}
        </span>
      </div>
      <button
        :if={@issue.pipeline_state == "plan_ready"}
        phx-click="promote_to_auto"
        phx-value-id={@issue.id}
        data-confirm={"Promote #{@issue.repo}##{@issue.number} to auto? An implement session will run against the reviewed plan and open a PR."}
        class="mt-1.5 font-display uppercase text-[10px] tracking-widest px-1.5 py-0.5 border border-accent text-accent rounded-sm hover:bg-accent hover:text-bg"
      >
        Implement
      </button>
      <button
        :if={@issue.pipeline_state == "failed"}
        phx-click="retry_issue"
        phx-value-id={@issue.id}
        data-confirm={"Retry #{@issue.repo}##{@issue.number}?"}
        class="mt-1.5 font-display uppercase text-[10px] tracking-widest px-1.5 py-0.5 border border-alert text-alert rounded-sm hover:bg-alert hover:text-bg"
      >
        Retry
      </button>
    </article>
    """
  end

  defp route_chip("auto"), do: "bg-accent/20 text-accent"
  defp route_chip("plan"), do: "bg-surface-2 text-ink"
  defp route_chip("skip"), do: "bg-surface-2 text-ink-dim"
  defp route_chip(_), do: "bg-surface-2 text-ink-dim"

  # Maps a run error string to the short badge shown on failed issue cards.
  defp run_reason_badge(nil), do: nil

  defp run_reason_badge(error) do
    cond do
      String.starts_with?(error, "turn cap ") -> error
      error =~ "operator" -> "operator kill"
      error =~ "reaped" or error =~ "daemon shutdown" -> "orphaned by restart"
      error =~ "timeout" -> "timeout"
      error =~ "no result envelope" -> "crashed"
      true -> nil
    end
  end

  defp phase_label("verifying"), do: "running tests"
  defp phase_label("pushing"), do: "pushing"
  defp phase_label("opening_pr"), do: "opening pr"
  defp phase_label(_), do: nil
end
