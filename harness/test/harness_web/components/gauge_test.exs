defmodule HarnessWeb.Components.GaugeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HarnessWeb.Components.Gauge

  defp render_gauge(assigns) do
    render_component(&Gauge.gauge/1, assigns)
  end

  defp base do
    %{id: "g", label: "Weekly", value: 50.0, max: 100.0, redline: 80.0, display: "50%"}
  end

  test "needle angle spans the 240° sweep" do
    assert Gauge.angle(0.0, 100.0) == -120.0
    assert Gauge.angle(50.0, 100.0) == 0.0
    assert Gauge.angle(100.0, 100.0) == 120.0
    # over-scale values clamp at full deflection
    assert Gauge.angle(250.0, 100.0) == 120.0
  end

  test "renders needle rotation, red zone, ticks, and odometer" do
    html = render_gauge(base())

    assert html =~ "rotate(0.0deg)"
    assert html =~ ~s|stroke="var(--color-alert)"|
    assert html =~ "gauge-needle"
    assert html =~ "50%"
    # 21 ticks, majors included
    assert html |> String.split("<line") |> length() == 22
  end

  test "stale gauges are dimmed" do
    assert render_gauge(Map.put(base(), :stale, true)) =~ "opacity-40"
    refute render_gauge(base()) =~ "opacity-40"
  end

  test "accessible label carries the reading" do
    assert render_gauge(base()) =~ ~s(aria-label="Weekly: 50%")
  end
end
