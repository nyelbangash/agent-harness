defmodule HarnessWeb.Components.Gauge do
  @moduledoc """
  Round analog gauge in the spirit of a vintage VDO instrument cluster
  (spec §12): 240° sweep, fine tick marks, a red zone starting at the gate
  threshold, thin ivory needle, odometer-style numerals beneath. Flat and
  precise — no chrome.

  Server-rendered SVG; the needle is rotated with an inline CSS transform,
  so LiveView patches animate via the `.gauge-needle` transition in app.css
  (which `prefers-reduced-motion` disables). No JS hook.
  """

  use Phoenix.Component

  @sweep 240.0
  @start_angle -120.0
  @radius 78.0
  @cx 100.0
  @cy 100.0

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: ~s(dial label, e.g. "5-HR SESSION")
  attr :value, :float, required: true
  attr :max, :float, required: true, doc: "full-scale value"
  attr :redline, :float, required: true, doc: "red zone start, in value units"
  attr :display, :string, required: true, doc: ~s(odometer text, e.g. "42%")
  attr :sublabel, :string, default: nil, doc: ~s(small note under the odometer, e.g. "est.")
  attr :stale, :boolean, default: false, doc: "dim the dial when the signal is stale"

  def gauge(assigns) do
    fraction = clamp(assigns.value / max(assigns.max, 0.0001))
    angle = @start_angle + @sweep * fraction
    red_from = clamp(assigns.redline / max(assigns.max, 0.0001))

    assigns =
      assign(assigns,
        angle: Float.round(angle, 2),
        red_arc: arc_path(red_from, 1.0),
        ticks: ticks()
      )

    ~H"""
    <div
      id={@id}
      class={["flex flex-col items-center select-none", @stale && "opacity-40"]}
      data-value={@value}
      data-testid="gauge"
    >
      <span class="font-display font-semibold uppercase tracking-[0.18em] text-[11px] text-ink-dim">
        {@label}
      </span>
      <svg
        viewBox="0 0 200 200"
        class="w-full max-w-[180px]"
        role="img"
        aria-label={"#{@label}: #{@display}"}
      >
        <circle
          cx="100"
          cy="100"
          r="92"
          fill="var(--color-surface)"
          stroke="var(--color-surface-2)"
          stroke-width="1"
        />

        <path d={@red_arc} fill="none" stroke="var(--color-alert)" stroke-width="5" opacity="0.9" />

        <g :for={tick <- @ticks}>
          <line
            x1="100"
            y1={if tick.major, do: "14", else: "18"}
            x2="100"
            y2="25"
            stroke={if tick.major, do: "var(--color-ink)", else: "var(--color-accent)"}
            stroke-width={if tick.major, do: "2", else: "1"}
            opacity={if tick.major, do: "0.9", else: "0.45"}
            transform={"rotate(#{tick.angle}, 100, 100)"}
          />
        </g>

        <g
          class="gauge-needle"
          style={"transform-box: view-box; transform-origin: 50% 50%; transform: rotate(#{@angle}deg);"}
        >
          <polygon points="98.6,102 101.4,102 100.4,30 99.6,30" fill="var(--color-ink)" />
          <polygon points="97,108 103,108 101.5,88 98.5,88" fill="var(--color-accent)" opacity="0.6" />
        </g>
        <circle
          cx="100"
          cy="100"
          r="6"
          fill="var(--color-surface-2)"
          stroke="var(--color-ink)"
          stroke-width="1.5"
        />
      </svg>
      <div class="-mt-5 px-3 py-0.5 rounded-sm bg-bg border border-surface-2">
        <span class="font-mono text-sm tabular-nums text-ink" data-testid="gauge-odometer">{@display}</span>
      </div>
      <span :if={@sublabel} class="mt-1 font-mono text-[10px] text-ink-dim tabular-nums">{@sublabel}</span>
    </div>
    """
  end

  @doc "Needle angle for a value (for tests)."
  def angle(value, max), do: @start_angle + @sweep * clamp(value / max(max, 0.0001))

  defp clamp(fraction), do: fraction |> max(0.0) |> min(1.0)

  # minor tick every 5% of scale, major every 25%
  defp ticks do
    for i <- 0..20 do
      %{angle: Float.round(@start_angle + @sweep * i / 20, 2), major: rem(i, 5) == 0}
    end
  end

  # arc along the dial face between two scale fractions
  defp arc_path(from, to) do
    {x1, y1} = point(from)
    {x2, y2} = point(to)
    large_arc = if (to - from) * @sweep > 180.0, do: 1, else: 0
    "M #{x1} #{y1} A #{@radius} #{@radius} 0 #{large_arc} 1 #{x2} #{y2}"
  end

  defp point(fraction) do
    theta = (@start_angle + @sweep * fraction) * :math.pi() / 180.0
    x = @cx + @radius * :math.sin(theta)
    y = @cy - @radius * :math.cos(theta)
    {Float.round(x, 2), Float.round(y, 2)}
  end
end
