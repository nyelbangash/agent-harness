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

    # live streaming: a new event appears without a reload
    Runs.append_event!(run, 3, "text", %{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => "found it in widget.ex"}]}
    })

    assert render(view) =~ "found it in widget.ex"
  end
end
