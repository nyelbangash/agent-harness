defmodule HarnessWeb.OverviewLive do
  @moduledoc """
  Mission Control home: the instrument cluster (four gauges), the live
  activity feed, and the "needs you" queue. Answers "what is the system
  doing, is it healthy, and what needs me?" at a glance (spec §12).
  """

  use HarnessWeb, :live_view

  import HarnessWeb.Components.Gauge

  alias Harness.{GitHub, Policy, Runs, Usage}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runs.subscribe()
      GitHub.subscribe()
      Harness.Briefing.subscribe()
      Harness.Manager.LampServer.subscribe()
      :timer.send_interval(30_000, self(), :tick)
    end

    recent = Runs.recent_runs(30)

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> assign(gauge_assigns())
     |> assign(:needs_you, GitHub.needs_attention())
     |> assign(:briefing, Harness.Briefing.latest_undismissed())
     |> assign(:lamps, Harness.Manager.LampServer.get_all())
     |> assign(:manager_last_sweep, Harness.Manager.LampServer.last_sweep_at())
     |> assign(:any_runs?, recent != [])
     |> stream(:activity, recent)}
  end

  @impl true
  def handle_info({:run_started, %{kind: "manager"}}, socket), do: {:noreply, socket}

  def handle_info({:run_started, run}, socket) do
    {:noreply,
     socket
     |> assign(:any_runs?, true)
     |> stream_insert(:activity, run, at: 0, limit: 30)}
  end

  def handle_info({:run_updated, %{kind: "manager"}}, socket), do: {:noreply, socket}

  def handle_info({:run_updated, run}, socket) do
    {:noreply,
     socket
     |> stream_insert(:activity, run)
     |> assign(gauge_assigns())}
  end

  def handle_info({:lamps_updated, lamps}, socket) do
    {:noreply,
     socket
     |> assign(:lamps, lamps)
     |> assign(:manager_last_sweep, Harness.Manager.LampServer.last_sweep_at())}
  end

  def handle_info({:run_event, _event}, socket), do: {:noreply, socket}

  def handle_info({:issue_updated, _issue}, socket) do
    {:noreply, assign(socket, :needs_you, GitHub.needs_attention())}
  end

  def handle_info({:usage_sample, _}, socket), do: {:noreply, assign(socket, gauge_assigns())}

  def handle_info({:usage_mode_changed, _}, socket),
    do: {:noreply, assign(socket, gauge_assigns())}

  def handle_info(:tick, socket) do
    # stream rows only re-render on insert — refresh running rows so their
    # elapsed-seconds counters advance
    socket =
      Enum.reduce(Runs.running_runs(), assign(socket, gauge_assigns()), fn run, acc ->
        stream_insert(acc, :activity, run)
      end)

    {:noreply, socket}
  end

  def handle_info({:briefing_updated, briefing}, socket) do
    {:noreply, assign(socket, :briefing, briefing)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("dismiss_briefing", %{"id" => id}, socket) do
    briefing = Harness.Repo.get!(Harness.Briefing, String.to_integer(id))
    Harness.Briefing.dismiss!(briefing)
    {:noreply, assign(socket, :briefing, nil)}
  end

  defp gauge_assigns do
    policy = Policy.get()
    gates = policy.utilization_gates
    samples = Usage.latest_samples()
    oauth = samples["oauth_api"]
    stale = Usage.health() in [:stale, :schema_drift]

    five_hour = (oauth && oauth.five_hour_utilization) || 0.0
    seven_day = (oauth && oauth.seven_day_utilization) || 0.0
    opus_hours = Usage.opus_hours_this_week()
    opus_cap = policy.budgets.opus_hours_weekly_cap / 1
    overflow = Usage.overflow_usd_this_week() || 0.0
    overflow_cap = policy.budgets.overflow_usd_weekly_cap / 1

    %{
      usage_stale: stale,
      gauges: [
        %{
          id: "gauge-five-hour",
          label: "5-hr Session",
          value: five_hour,
          max: 100.0,
          redline: gates.pause_above * 100,
          display: "#{round(five_hour)}%",
          sublabel: nil,
          stale: stale
        },
        %{
          id: "gauge-weekly",
          label: "Weekly",
          value: seven_day,
          max: 100.0,
          redline: gates.plan_only_above * 100,
          display: "#{round(seven_day)}%",
          sublabel: "trailing 7d",
          stale: stale
        },
        %{
          id: "gauge-opus",
          label: "Opus Hours",
          value: opus_hours / 1,
          max: opus_cap * 1.2,
          redline: opus_cap,
          display: "#{:erlang.float_to_binary(opus_hours / 1, decimals: 1)} h",
          sublabel: "cap #{round(opus_cap)} h",
          stale: false
        },
        %{
          id: "gauge-overflow",
          label: "Overflow $",
          value: overflow / 1,
          max: overflow_cap * 1.2,
          redline: overflow_cap,
          display: "$#{:erlang.float_to_binary(overflow / 1, decimals: 2)}",
          sublabel: "est. · cap $#{round(overflow_cap)}",
          stale: false
        }
      ]
    }
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
        <div :if={@briefing} class="mb-6 rounded-sm border border-surface-2 bg-surface">
          <div class="flex items-center justify-between px-4 py-2 border-b border-surface-2">
            <span class="font-display uppercase tracking-[0.16em] text-[11px] text-ink-dim">
              Morning briefing · {@briefing.date}
            </span>
            <button
              phx-click="dismiss_briefing"
              phx-value-id={@briefing.id}
              class="font-display uppercase text-[10px] tracking-widest px-2 py-0.5 border border-surface-2 text-ink-dim rounded-sm hover:text-ink"
            >
              Dismiss
            </button>
          </div>
          <div class="px-4 py-3 prose prose-sm prose-invert max-w-none font-mono text-xs text-ink">
            {Phoenix.HTML.raw(Earmark.as_html!(@briefing.markdown))}
          </div>
        </div>

        <div
          :if={@usage_stale and @usage_health == :schema_drift}
          class="mb-6 px-4 py-3 rounded-sm border border-alert/60 bg-alert/10 font-mono text-sm text-ink"
          data-testid="stale-banner"
        >
          <span class="text-alert font-medium">USAGE SCHEMA DRIFT</span>
          — last 3 oauth_api samples parsed to nil utilization; the claude.ai usage endpoint shape may have changed. Run <code>mix harness.doctor</code>.
        </div>
        <div
          :if={@usage_stale and @usage_health != :schema_drift}
          class="mb-6 px-4 py-3 rounded-sm border border-alert/60 bg-alert/10 font-mono text-sm text-ink"
          data-testid="stale-banner"
        >
          <span class="text-alert font-medium">USAGE TELEMETRY STALE</span>
          — the claude.ai usage endpoint hasn't answered recently; gates are failing closed to plan-only.
        </div>

        <section aria-label="instrument cluster" class="mb-10">
          <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
            <.gauge
              :for={gauge <- @gauges}
              id={gauge.id}
              label={gauge.label}
              value={gauge.value}
              max={gauge.max}
              redline={gauge.redline}
              display={gauge.display}
              sublabel={gauge.sublabel}
              stale={gauge.stale}
            />
          </div>
        </section>

        <section aria-label="manager lamps" class="mb-6 flex flex-wrap items-center gap-2">
          <div class="flex items-center gap-2 px-3 py-1.5 rounded-sm bg-surface border border-surface-2 font-mono text-[10px] uppercase tracking-widest text-ink-dim">
            <span class={[
              "inline-block size-2 rounded-full",
              if(Enum.any?(@lamps, &(&1.status == :on)), do: "bg-alert animate-pulse", else: "bg-ok")
            ]} />
            <span>manager</span>
            <span :if={@manager_last_sweep} class="normal-case tracking-normal">
              · swept {Calendar.strftime(@manager_last_sweep, "%H:%M:%S")}
            </span>
            <span
              :if={Enum.all?(@lamps, &(&1.status != :on))}
              class="text-ok normal-case tracking-normal"
            >
              · all clear
            </span>
          </div>
          <%= for lamp <- @lamps, lamp.status == :on do %>
            <div class="flex items-center gap-2 px-3 py-1.5 rounded-sm bg-surface border border-alert/60 font-mono text-[11px] text-alert">
              <span class="inline-block size-2 rounded-full bg-alert animate-pulse" />
              <span>{lamp.class |> to_string() |> String.replace("_", " ")}</span>
              <span :if={lamp.detail} class="text-ink-dim">&nbsp;{lamp.detail}</span>
            </div>
          <% end %>
        </section>

        <div class="grid lg:grid-cols-5 gap-8 md:flex-1 md:min-h-0 md:auto-rows-fr">
          <section aria-label="activity" class="lg:col-span-3 md:flex md:flex-col md:min-h-0">
            <h2 class="font-display uppercase tracking-[0.16em] text-[12px] text-ink-dim mb-3">
              Activity
            </h2>
            <div
              id="activity"
              phx-update="stream"
              class="divide-y divide-surface-2 md:flex-1 md:min-h-0 md:overflow-y-auto"
            >
              <div
                :for={{dom_id, run} <- @streams.activity}
                id={dom_id}
                class="py-2.5 flex items-center gap-3"
              >
                <.status_dot status={run.status} />
                <span class="font-mono text-xs text-ink-dim tabular-nums shrink-0">#{run.id}</span>
                <span class="font-display uppercase tracking-wide text-[11px] text-ink shrink-0">{run.kind}</span>
                <span class="font-mono text-xs text-ink-dim truncate flex-1">{run.ref}</span>
                <span class="font-mono text-[11px] text-ink-dim tabular-nums shrink-0">{run.model}</span>
                <span class="font-mono text-[11px] tabular-nums shrink-0" data-status={run.status}>
                  {status_text(run)}
                </span>
                <button
                  :if={run.status == "running"}
                  phx-click="kill_run"
                  phx-value-id={run.id}
                  data-confirm={"Kill run ##{run.id}?"}
                  class="font-display uppercase text-[10px] tracking-widest px-2 py-0.5 border border-alert text-alert rounded-sm hover:bg-alert hover:text-ink"
                >
                  Kill
                </button>
              </div>
            </div>
            <p :if={!@any_runs?} class="font-body text-sm text-ink-dim py-4">
              No runs yet — assign yourself a GitHub issue in a policy repo and the pipeline takes it from there.
            </p>
          </section>

          <section aria-label="needs you" class="lg:col-span-2 md:flex md:flex-col md:min-h-0">
            <h2 class="font-display uppercase tracking-[0.16em] text-[12px] text-ink-dim mb-3">
              Needs you
            </h2>
            <div class="space-y-3 md:flex-1 md:min-h-0 md:overflow-y-auto">
              <div
                :for={issue <- @needs_you}
                class="rounded-sm bg-surface border border-surface-2 px-4 py-3"
                data-testid="needs-you-card"
              >
                <div class="flex items-center gap-2 mb-1">
                  <span class="font-mono text-xs text-ink-dim tabular-nums">{issue.repo}#{issue.number}</span>
                  <span class={[
                    "font-display uppercase text-[10px] tracking-widest px-1.5 py-0.5 rounded-sm",
                    issue.pipeline_state == "failed" && "bg-alert/20 text-alert",
                    issue.pipeline_state == "plan_ready" && "bg-accent/20 text-accent"
                  ]}>
                    {String.replace(issue.pipeline_state, "_", " ")}
                  </span>
                </div>
                <p class="font-body text-sm text-ink mb-2">{issue.title}</p>
                <div :if={plan = List.first(issue.plans)} class="font-mono text-[11px] text-ink-dim">
                  <span :if={plan.branch}>branch: {plan.branch}</span>
                  <span :if={plan.issue_comment_id}>plan posted to issue</span>
                  <button
                    :if={issue.pipeline_state == "plan_ready"}
                    phx-click="promote_to_auto"
                    phx-value-id={issue.id}
                    data-confirm={"Promote #{issue.repo}##{issue.number} to auto? An implement session will run against the reviewed plan and open a PR."}
                    class="ml-2 px-1.5 py-0.5 border border-accent text-accent rounded-sm hover:bg-accent hover:text-bg"
                  >
                    Promote to auto
                  </button>
                </div>
                <button
                  :if={issue.pipeline_state == "failed"}
                  phx-click="retry_issue"
                  phx-value-id={issue.id}
                  data-confirm={"Retry #{issue.repo}##{issue.number}?"}
                  class="px-1.5 py-0.5 border border-alert text-alert rounded-sm hover:bg-alert hover:text-bg font-display uppercase text-[10px] tracking-widest"
                >
                  Retry
                </button>
              </div>
              <p :if={@needs_you == []} class="font-body text-sm text-ink-dim py-4">
                Nothing needs you. Plans ready for review and failed runs land here.
              </p>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :status, :string, required: true

  defp status_dot(assigns) do
    ~H"""
    <span
      class={[
        "inline-block size-2 rounded-full shrink-0",
        @status in ["running", "verifying", "pushing", "opening_pr"] && "bg-accent animate-pulse",
        @status == "succeeded" && "bg-ok",
        @status in ["failed", "killed"] && "bg-alert",
        @status == "queued" && "bg-ink-dim"
      ]}
      title={@status}
    />
    """
  end

  defp status_text(%{status: status, started_at: %DateTime{} = started})
       when status in ["running", "verifying", "pushing", "opening_pr"] do
    "#{DateTime.diff(DateTime.utc_now(), started, :second)}s"
  end

  defp status_text(%{status: status, started_at: %DateTime{} = s, ended_at: %DateTime{} = e}) do
    "#{status} · #{DateTime.diff(e, s, :second)}s"
  end

  defp status_text(%{status: status}), do: status
end
