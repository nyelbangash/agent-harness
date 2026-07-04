defmodule HarnessWeb.OverviewLiveTest do
  use HarnessWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Harness.Fixtures

  alias Harness.{Runs, Usage}

  @moduletag :capture_log

  test "renders the four-gauge cluster with redlines from policy", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    for label <- ["5-hr Session", "Weekly", "Opus Hours", "Overflow $"] do
      assert html =~ label
    end

    # four dials
    assert html |> String.split(~s(data-testid="gauge")) |> length() == 5
    # overflow gauge is explicitly an estimate
    assert html =~ "est."
  end

  test "no usage samples → stale banner + plan-only failsafe", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "USAGE TELEMETRY STALE"
    assert html =~ "failing closed"
  end

  test "a fresh usage sample clears the banner and moves the needles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    Usage.record_oauth_sample!(%{
      five_hour_utilization: 42.0,
      seven_day_utilization: 30.0,
      raw: %{}
    })

    html = render(view)
    refute html =~ "USAGE TELEMETRY STALE"
    assert html =~ "42%"
    assert html =~ "30%"
  end

  test "runs stream into the activity feed live", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "No runs yet"

    run = Runs.create_run!(%{kind: "triage", status: "queued", model: "sonnet", ref: "o/r#1"})
    Runs.update_run!(run, %{status: "running", started_at: DateTime.utc_now()})

    html = render(view)
    assert html =~ "o/r#1"
    assert html =~ "triage"
    refute html =~ "No runs yet"
    # running rows get a kill button
    assert html =~ "Kill"
  end

  test "plan_ready issues appear in the needs-you queue with their plan", %{conn: conn} do
    issue = issue_fixture(%{title: "Improve the flux capacitor", pipeline_state: "triaged"})
    run = Runs.create_run!(%{kind: "plan", status: "succeeded", issue_id: issue.id})

    Harness.GitHub.record_plan!(%{
      issue_id: issue.id,
      run_id: run.id,
      plan_path: "/tmp/PLAN.md",
      context_path: "/tmp/CONTEXT.md",
      branch: "harness/plans/issue-#{issue.number}",
      summary: "A plan"
    })

    {:ok, view, _} = live(conn, ~p"/")
    Harness.GitHub.transition!(issue, "plan_ready")

    html = render(view)
    assert html =~ "Improve the flux capacitor"
    assert html =~ "plan ready"
    assert html =~ "harness/plans/issue-#{issue.number}"
    assert html =~ "Promote to auto"
  end

  test "the rail shows the mode and the master kill", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Plan-Only"
    assert html =~ "Kill all"
    assert html =~ "Kill every running agent session?"
  end
end
