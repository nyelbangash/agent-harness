defmodule HarnessWeb.RunsLive do
  @moduledoc "Phase 2 placeholder — nav slot exists so the layout doesn't churn."

  use HarnessWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Runs")}
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
      <h1 class="font-display uppercase tracking-[0.16em] text-sm text-ink-dim mb-6">Runs</h1>
      <p class="font-body text-sm text-ink-dim">
        The run console — live streaming transcripts, collapsed tool calls, and a kill button that
        means it — lands in Phase 2. Until then the Overview's activity feed shows every session,
        and running rows carry a kill button.
      </p>
    </Layouts.app>
    """
  end
end
