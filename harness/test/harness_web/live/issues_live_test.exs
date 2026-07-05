defmodule HarnessWeb.IssuesLiveTest do
  use HarnessWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Harness.Fixtures

  alias Harness.GitHub
  alias Harness.Runs

  @moduletag :capture_log

  test "empty state points at policy.yaml", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/issues")
    assert html =~ "No issues yet"
    assert html =~ "github.repos"
  end

  test "issues render in their board columns with triage chips", %{conn: conn} do
    incoming = issue_fixture(%{title: "Fresh issue", pipeline_state: "incoming"})
    triaged = issue_fixture(%{title: "Sized issue", pipeline_state: "triaged"})

    GitHub.record_triage!(%{
      issue_id: triaged.id,
      proposed_route: "auto",
      confidence: 0.85,
      estimated_scope: "s",
      risk_flags: ["touches_ci"],
      final_route: "plan",
      decision_reason: "risk_flags_present"
    })

    {:ok, _view, html} = live(conn, ~p"/issues")

    assert [_, incoming_col] = String.split(html, ~s(data-column="incoming"))
    assert incoming_col =~ "Fresh issue"

    [_, triaged_col] = String.split(html, ~s(data-column="triaged"))
    assert triaged_col =~ "Sized issue"
    assert triaged_col =~ "0.85"
    assert triaged_col =~ "touches_ci"

    assert html =~ "https://github.com/owner/fixture/issues/#{incoming.number}"
  end

  test "cards move columns live on pipeline transitions", %{conn: conn} do
    issue = issue_fixture(%{title: "Moving issue", pipeline_state: "incoming"})
    {:ok, view, html} = live(conn, ~p"/issues")

    [_, incoming_col] = String.split(html, ~s(data-column="incoming"))
    assert incoming_col =~ "Moving issue"

    GitHub.transition!(issue, "planning")

    html = render(view)
    [_, in_progress_col] = String.split(html, ~s(data-column="in_progress"))
    assert in_progress_col =~ "Moving issue"
  end

  test "failed issues land in Done · Failed with the alert treatment", %{conn: conn} do
    issue_fixture(%{title: "Broken issue", pipeline_state: "failed"})

    {:ok, _view, html} = live(conn, ~p"/issues")
    [_, done_col] = String.split(html, ~s(data-column="done"))
    assert done_col =~ "Broken issue"
    assert done_col =~ "failed"
  end

  test "failed issue card shows operator kill reason badge", %{conn: conn} do
    issue = issue_fixture(%{title: "Killed issue", pipeline_state: "failed"})

    run =
      Runs.create_run!(%{
        kind: "implement",
        ref: "owner/fixture##{issue.number}",
        model: "sonnet",
        status: "queued",
        issue_id: issue.id
      })

    Runs.update_run!(run, %{status: "killed", error: "killed by operator"})

    {:ok, _view, html} = live(conn, ~p"/issues")
    [_, done_col] = String.split(html, ~s(data-column="done"))
    assert done_col =~ "operator kill"
  end

  test "failed issue card shows turn cap reason badge with counts", %{conn: conn} do
    issue = issue_fixture(%{title: "Capped issue", pipeline_state: "failed"})

    run =
      Runs.create_run!(%{
        kind: "implement",
        ref: "owner/fixture##{issue.number}",
        model: "sonnet",
        status: "queued",
        issue_id: issue.id
      })

    Runs.update_run!(run, %{status: "killed", error: "turn cap 41/40"})

    {:ok, _view, html} = live(conn, ~p"/issues")
    [_, done_col] = String.split(html, ~s(data-column="done"))
    assert done_col =~ "turn cap 41/40"
  end
end
