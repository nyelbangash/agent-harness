defmodule HarnessWeb.RunsLiveTest do
  use HarnessWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Harness.Runs

  @moduletag :capture_log

  test "lists sessions with their vitals", %{conn: conn} do
    run = Runs.create_run!(%{kind: "plan", ref: "o/r#9", model: "sonnet", status: "queued"})

    Runs.update_run!(run, %{
      status: "succeeded",
      turns: 12,
      tokens_out: 3400,
      started_at: DateTime.add(DateTime.utc_now(), -300, :second),
      ended_at: DateTime.utc_now()
    })

    {:ok, _view, html} = live(conn, ~p"/runs")
    assert html =~ "o/r#9"
    assert html =~ "300s"
    assert html =~ "succeeded"
  end

  test "detail pane renders the transcript with collapsed tool calls", %{conn: conn} do
    run = Runs.create_run!(%{kind: "triage", ref: "o/r#1", model: "sonnet", status: "running"})
    Runs.update_run!(run, %{status: "running", started_at: DateTime.utc_now()})

    Runs.append_event!(run, 1, "text", %{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => "reading the widget code"}]}
    })

    Runs.append_event!(run, 2, "tool_use", %{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "tool_use", "name" => "Read", "input" => %{}}]}
    })

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")
    assert html =~ "reading the widget code"
    assert html =~ "<details"
    assert html =~ "Read"
    assert html =~ "Kill"
    # transcript carries the pin-to-bottom hook
    assert html =~ "AutoScroll"

    # live streaming: a new event appears without a reload
    Runs.append_event!(run, 3, "text", %{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => "found it in widget.ex"}]}
    })

    assert render(view) =~ "found it in widget.ex"
  end

  test "killed run shows operator kill badge", %{conn: conn} do
    run = Runs.create_run!(%{kind: "implement", ref: "o/r#2", model: "sonnet", status: "queued"})
    Runs.update_run!(run, %{status: "killed", error: "killed by operator"})

    {:ok, _view, html} = live(conn, ~p"/runs")
    assert html =~ "killed"
    assert html =~ "operator kill"
  end

  test "killed run shows turn cap badge with counts", %{conn: conn} do
    run = Runs.create_run!(%{kind: "implement", ref: "o/r#3", model: "sonnet", status: "queued"})
    Runs.update_run!(run, %{status: "killed", error: "turn cap 41/40"})

    {:ok, _view, html} = live(conn, ~p"/runs")
    assert html =~ "turn cap 41/40"
  end

  test "failed run shows orphaned badge when reaped by janitor", %{conn: conn} do
    run = Runs.create_run!(%{kind: "triage", ref: "o/r#4", model: "sonnet", status: "queued"})

    Runs.update_run!(run, %{
      status: "failed",
      error: "reaped: no live run server (daemon restarted mid-run?)"
    })

    {:ok, _view, html} = live(conn, ~p"/runs")
    assert html =~ "orphaned by restart"
  end

  test "failed run shows crashed badge for missing result envelope", %{conn: conn} do
    run = Runs.create_run!(%{kind: "triage", ref: "o/r#5", model: "sonnet", status: "queued"})
    Runs.update_run!(run, %{status: "failed", error: "no result envelope (exit 1)"})

    {:ok, _view, html} = live(conn, ~p"/runs")
    assert html =~ "crashed"
  end

  test "detail pane shows reason badge next to status", %{conn: conn} do
    run = Runs.create_run!(%{kind: "plan", ref: "o/r#6", model: "sonnet", status: "queued"})
    Runs.update_run!(run, %{status: "killed", error: "killed by operator"})

    {:ok, _view, html} = live(conn, ~p"/runs/#{run.id}")
    assert html =~ "killed"
    assert html =~ "operator kill"
  end

  test "running row's turn counter updates via PubSub without page reload", %{conn: conn} do
    run = Runs.create_run!(%{kind: "plan", ref: "o/r#99", model: "sonnet", status: "running"})
    {:ok, view, html} = live(conn, ~p"/runs")

    assert html =~ "0"

    Runs.broadcast_counters(run.id, 7)
    assert render(view) =~ "7"

    Runs.update_run!(run, %{status: "succeeded", turns: 9, ended_at: DateTime.utc_now()})
    assert render(view) =~ "9"
  end

  test "queue strip shows slot occupancy and waiting depth", %{conn: conn} do
    Oban.insert!(Harness.GitHub.PlanWorker.new(%{issue_id: 1}))

    {:ok, _view, html} = live(conn, ~p"/runs")
    assert html =~ "1 waiting"
    assert html =~ "0/1"
  end
end
