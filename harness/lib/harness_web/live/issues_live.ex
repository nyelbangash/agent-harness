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
    {:done, "Done · Failed"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: GitHub.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Issues")
     |> assign(:columns, @columns)
     |> load_board()}
  end

  @impl true
  def handle_info({:issue_updated, _issue}, socket), do: {:noreply, load_board(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_board(socket) do
    board = GitHub.board()

    socket
    |> assign(:board, board)
    |> assign(:empty?, board == %{})
    |> attach_triages(board)
    |> attach_run_errors(board)
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

        <div
          :if={!@empty?}
          class="grid md:grid-cols-3 xl:grid-cols-5 gap-4 md:flex-1 md:min-h-0 md:auto-rows-fr"
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
              />
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :issue, :map, required: true
  attr :triage, :map, default: nil
  attr :run_error, :string, default: nil

  defp issue_card(assigns) do
    ~H"""
    <article
      class={[
        "rounded-sm bg-surface border px-3 py-2.5",
        if(@issue.pipeline_state == "failed", do: "border-alert/60", else: "border-surface-2")
      ]}
      data-testid="issue-card"
      data-issue-number={@issue.number}
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
      </div>

      <p class="font-body text-[13px] leading-snug text-ink mb-1.5">{@issue.title}</p>

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
end
