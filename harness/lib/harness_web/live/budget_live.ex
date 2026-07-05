defmodule HarnessWeb.BudgetLive do
  @moduledoc """
  Budget view (spec §12.5): utilization history sparklines, per-day token burn
  stacked by lane, Opus hours vs cap, overflow spend vs cap, and annotated
  calendar events (e.g. the July 13 limit change). All server-rendered SVG,
  same flat-instrument discipline as the gauges.
  """

  use HarnessWeb, :live_view

  alias Harness.{Policy, Usage}

  @lane_colors %{
    "triage" => "#8da9bf",
    "plan" => "#6f8aa0",
    "implement" => "#5f7487",
    "ideate" => "#4c5f70",
    "critique" => "#3a4a58"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Usage.subscribe()
      :timer.send_interval(60_000, self(), :refresh)
    end

    {:ok, socket |> assign(:page_title, "Budget") |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info({:usage_sample, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    policy = Policy.get()

    socket
    |> assign(:history, Usage.utilization_history(7))
    |> assign(:burn, Usage.token_burn_by_day(7))
    |> assign(:opus_hours, Usage.opus_hours_this_week())
    |> assign(:opus_cap, policy.budgets.opus_hours_weekly_cap)
    |> assign(:overflow, Usage.overflow_usd_this_week() || 0.0)
    |> assign(:overflow_cap, policy.budgets.overflow_usd_weekly_cap)
    |> assign(:calendar_notes, policy.calendar_notes)
    |> assign(:lane_colors, @lane_colors)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path="/budget"
      mode={@mode}
      usage_mode={@usage_mode}
      usage_health={@usage_health}
    >
      <div class="page-fit md:flex md:flex-col md:min-h-0 md:overflow-hidden">
        <h1 class="font-display uppercase tracking-[0.16em] text-sm text-ink-dim mb-6">Budget</h1>
        <div class="md:flex-1 md:min-h-0 md:overflow-y-auto">
          <div class="grid lg:grid-cols-2 gap-6 mb-8">
            <.cap_bar label="Opus hours (7d)" value={@opus_hours} cap={@opus_cap * 1.0} unit="h" />
            <.cap_bar
              label="Overflow spend (7d, est.)"
              value={@overflow}
              cap={@overflow_cap * 1.0}
              unit="$"
              prefix
            />
          </div>

          <section class="mb-8">
            <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-3">
              Utilization history · 7 days
            </h2>
            <div :if={@history == []} class="font-body text-sm text-ink-dim">
              No utilization samples yet — the poller records one every ~10 minutes.
            </div>
            <div :if={@history != []} class="space-y-3">
              <.sparkline label="5-hour" series={Enum.map(@history, & &1.five_hour)} />
              <.sparkline label="Weekly" series={Enum.map(@history, & &1.seven_day)} />
              <.sparkline label="Weekly Opus" series={Enum.map(@history, & &1.seven_day_opus)} />
            </div>
          </section>

          <section class="mb-8">
            <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-3">
              Token burn by lane · 7 days
            </h2>
            <div :if={@burn == []} class="font-body text-sm text-ink-dim">
              No runs in the last 7 days.
            </div>
            <div :if={@burn != []}>
              <.burn_chart burn={@burn} colors={@lane_colors} />
              <div class="flex gap-4 mt-2 flex-wrap">
                <span :for={{kind, color} <- @lane_colors} class="flex items-center gap-1.5">
                  <span class="inline-block size-2.5 rounded-sm" style={"background: #{color}"} />
                  <span class="font-mono text-[10px] text-ink-dim uppercase">{kind}</span>
                </span>
              </div>
            </div>
          </section>

          <section :if={@calendar_notes != []}>
            <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-3">
              Annotated events
            </h2>
            <ul class="space-y-1">
              <li :for={note <- @calendar_notes} class="font-mono text-[12px] text-ink-dim flex gap-2">
                <span class="text-accent">◆</span>{note}
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :float, required: true
  attr :cap, :float, required: true
  attr :unit, :string, required: true
  attr :prefix, :boolean, default: false

  defp cap_bar(assigns) do
    fraction = min(assigns.value / max(assigns.cap, 0.0001), 1.0)
    assigns = assign(assigns, fraction: fraction, over: assigns.value >= assigns.cap)

    ~H"""
    <div class="rounded-sm bg-surface border border-surface-2 p-4">
      <div class="flex items-baseline justify-between mb-2">
        <span class="font-display uppercase tracking-[0.12em] text-[11px] text-ink-dim">{@label}</span>
        <span class="font-mono text-sm tabular-nums text-ink">
          {if @prefix, do: @unit}{:erlang.float_to_binary(@value * 1.0,
            decimals: if(@prefix, do: 2, else: 1)
          )}{if !@prefix, do: " " <> @unit} / {round(@cap)}{if !@prefix, do: " " <> @unit}
        </span>
      </div>
      <div class="h-2 rounded-full bg-bg overflow-hidden">
        <div
          class="h-full rounded-full"
          style={"width: #{Float.round(@fraction * 100, 1)}%; background: #{if @over, do: "var(--color-alert)", else: "var(--color-accent)"}"}
        />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :series, :list, required: true

  defp sparkline(assigns) do
    values = Enum.map(assigns.series, &((&1 || 0.0) * 1.0))
    points = spark_points(values, 600, 40)
    latest = List.last(values) || 0.0
    assigns = assign(assigns, points: points, latest: latest)

    ~H"""
    <div class="flex items-center gap-3">
      <span class="font-mono text-[11px] text-ink-dim w-24 shrink-0">{@label}</span>
      <svg viewBox="0 0 600 40" class="flex-1 h-8" preserveAspectRatio="none">
        <polyline points={@points} fill="none" stroke="var(--color-accent)" stroke-width="1.5" />
      </svg>
      <span class="font-mono text-[11px] tabular-nums text-ink w-12 text-right">{round(@latest)}%</span>
    </div>
    """
  end

  attr :burn, :list, required: true
  attr :colors, :map, required: true

  defp burn_chart(assigns) do
    max_total = assigns.burn |> Enum.map(& &1.total) |> Enum.max(fn -> 1 end) |> max(1)
    assigns = assign(assigns, max_total: max_total)

    ~H"""
    <div class="flex items-end gap-2 h-40">
      <div :for={day <- @burn} class="flex-1 flex flex-col items-center gap-1">
        <div class="w-full flex flex-col-reverse" style="height: 128px">
          <div
            :for={{kind, color} <- @colors}
            :if={Map.get(day.by_kind, kind, 0) > 0}
            style={"height: #{Float.round(Map.get(day.by_kind, kind, 0) / @max_total * 128, 1)}px; background: #{color}"}
            title={"#{kind}: #{Map.get(day.by_kind, kind, 0)} tok"}
          />
        </div>
        <span class="font-mono text-[9px] text-ink-dim">{Calendar.strftime(day.date, "%m/%d")}</span>
      </div>
    </div>
    """
  end

  # normalize a 0..100 series to a polyline over w×h (flat line if <2 points)
  defp spark_points([], _w, _h), do: "0,40 600,40"
  defp spark_points([_only], _w, h), do: "0,#{h} 600,#{h}"

  defp spark_points(values, w, h) do
    n = length(values)

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {v, i} ->
      x = i / (n - 1) * w
      y = h - min(v, 100.0) / 100.0 * h
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
  end
end
