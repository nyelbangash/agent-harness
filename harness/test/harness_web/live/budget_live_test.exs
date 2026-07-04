defmodule HarnessWeb.BudgetLiveTest do
  use HarnessWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Harness.{Runs, Usage}

  @moduletag :capture_log

  test "empty state explains the pollers", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/budget")
    assert html =~ "No utilization samples yet"
    assert html =~ "No runs in the last 7 days"
  end

  test "renders caps, sparklines, token burn, and calendar annotations", %{conn: conn} do
    Usage.record_oauth_sample!(%{
      five_hour_utilization: 40.0,
      seven_day_utilization: 65.0,
      seven_day_opus_utilization: 20.0,
      raw: %{}
    })

    now = DateTime.utc_now()

    Runs.create_run!(%{kind: "critique", status: "succeeded", model: "opus"})
    |> Runs.update_run!(%{
      tokens_out: 5000,
      started_at: DateTime.add(now, -7200, :second),
      ended_at: DateTime.add(now, -3600, :second)
    })

    Runs.create_run!(%{kind: "implement", status: "succeeded", model: "sonnet"})
    |> Runs.update_run!(%{tokens_out: 12_000, used_overage: true, cost_estimate: 2.5})

    {:ok, _view, html} = live(conn, ~p"/budget")

    # opus-hours cap bar (1h used against 18h cap)
    assert html =~ "Opus hours"
    assert html =~ "/ 18"
    # overflow cap bar
    assert html =~ "Overflow spend"
    assert html =~ "/ 25"
    # sparklines
    assert html =~ "5-hour"
    assert html =~ "Weekly Opus"
    assert html =~ "<polyline"
    # token burn stacked chart + legend
    assert html =~ "Token burn by lane"
    # the calendar note from policy
    assert html =~ "2026-07-13"
  end

  test "a cap breach turns the bar red", %{conn: conn} do
    # 30h opus against an 18h cap
    now = DateTime.utc_now()

    Runs.create_run!(%{kind: "critique", status: "succeeded", model: "opus"})
    |> Runs.update_run!(%{
      started_at: DateTime.add(now, -30 * 3600, :second),
      ended_at: now
    })

    {:ok, _view, html} = live(conn, ~p"/budget")
    assert html =~ "var(--color-alert)"
  end
end
