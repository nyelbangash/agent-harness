defmodule HarnessWeb.IssuesLiveTest do
  use HarnessWeb.ConnCase, async: false
  use Oban.Testing, repo: Harness.Repo, engine: Oban.Engines.Lite

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

  test "failed cards show a retry button", %{conn: conn} do
    issue_fixture(%{title: "Failed card", pipeline_state: "failed"})
    {:ok, _view, html} = live(conn, ~p"/issues")
    assert html =~ "Retry"
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

  test "a dismissed issue does not render, and the row survives underneath", %{conn: conn} do
    issue = issue_fixture(%{title: "Dismissed already", pipeline_state: "failed"})
    GitHub.dismiss_issue!(issue)

    {:ok, _view, html} = live(conn, ~p"/issues")
    refute html =~ "Dismissed already"
    assert GitHub.get_issue!(issue.id).dismissed_at
  end

  test "clicking a card selects it and shows the trash-selected action", %{conn: conn} do
    issue = issue_fixture(%{title: "Selectable issue", pipeline_state: "incoming"})
    {:ok, view, html} = live(conn, ~p"/issues")
    refute html =~ "Trash selected"

    html =
      view
      |> render_click("select_card", %{"id" => "#{issue.id}", "shift" => false, "meta" => false})

    assert html =~ "Trash selected"
    assert html =~ "ring-2 ring-accent"
  end

  test "trash_selected dismisses the selected card without deleting the row", %{conn: conn} do
    issue = issue_fixture(%{title: "Bulk-trashed issue", pipeline_state: "incoming"})
    {:ok, view, _html} = live(conn, ~p"/issues")

    view
    |> render_click("select_card", %{"id" => "#{issue.id}", "shift" => false, "meta" => false})

    render_click(view, "trash_selected", %{})

    # the dismiss broadcasts {:issue_updated, issue} back to this same view
    # process asynchronously — force it to drain that message before asserting
    html = render(view)

    refute html =~ "Bulk-trashed issue"
    assert GitHub.get_issue!(issue.id).dismissed_at
  end

  test "meta-click toggles a second card into the selection, trashing both", %{conn: conn} do
    a = issue_fixture(%{title: "Card A", pipeline_state: "incoming"})
    b = issue_fixture(%{title: "Card B", pipeline_state: "incoming"})
    {:ok, view, _html} = live(conn, ~p"/issues")

    view |> render_click("select_card", %{"id" => "#{a.id}", "shift" => false, "meta" => false})

    html =
      view
      |> render_click("select_card", %{"id" => "#{b.id}", "shift" => false, "meta" => true})

    assert html =~ "Trash selected (2)"

    render_click(view, "trash_selected", %{})

    assert GitHub.get_issue!(a.id).dismissed_at
    assert GitHub.get_issue!(b.id).dismissed_at
  end

  test "trash_drop dismisses the dragged issue ids", %{conn: conn} do
    issue = issue_fixture(%{title: "Dragged off", pipeline_state: "incoming"})
    {:ok, view, _html} = live(conn, ~p"/issues")

    render_click(view, "trash_drop", %{"ids" => ["#{issue.id}"]})
    html = render(view)

    refute html =~ "Dragged off"
    assert GitHub.get_issue!(issue.id).dismissed_at
  end

  test "plan_ready cards in the review column show an Implement button, pr_open cards do not", %{
    conn: conn
  } do
    issue_fixture(%{title: "Ready to implement", pipeline_state: "plan_ready"})
    issue_fixture(%{title: "Already has a PR", pipeline_state: "pr_open"})

    {:ok, _view, html} = live(conn, ~p"/issues")
    [_, review_col] = String.split(html, ~s(data-column="review"))

    assert review_col =~ "Ready to implement"
    assert review_col =~ "Already has a PR"
    assert review_col =~ "Implement"

    cards = String.split(review_col, "<article ")
    ready_card = Enum.find(cards, &(&1 =~ "Ready to implement"))
    pr_open_card = Enum.find(cards, &(&1 =~ "Already has a PR"))

    assert ready_card =~ "Implement"
    refute pr_open_card =~ "Implement"
  end

  test "clicking Implement on the board queues an implement job and moves the card", %{
    conn: conn
  } do
    issue = issue_fixture(%{title: "Board promote me", pipeline_state: "plan_ready"})

    {:ok, view, html} = live(conn, ~p"/issues")
    [_, review_col] = String.split(html, ~s(data-column="review"))
    assert review_col =~ "Board promote me"

    render_click(view, "promote_to_auto", %{"id" => "#{issue.id}"})

    html = render(view)
    [_, in_progress_col] = String.split(html, ~s(data-column="in_progress"))
    assert in_progress_col =~ "Board promote me"
    assert GitHub.get_issue!(issue.id).pipeline_state == "implementing"
  end

  test "clicking Implement twice on the board surfaces the already-queued flash", %{conn: conn} do
    issue = issue_fixture(%{title: "Double clicked", pipeline_state: "plan_ready"})

    {:ok, view, _html} = live(conn, ~p"/issues")

    render_click(view, "promote_to_auto", %{"id" => "#{issue.id}"})
    html = render_click(view, "promote_to_auto", %{"id" => "#{issue.id}"})

    assert html =~ "Already queued for implementation"
  end
   
  describe "issue detail view" do
    test "clicking a card title patches to the detail route and shows run history", %{conn: conn} do
      issue = issue_fixture(%{title: "Detail me", pipeline_state: "pr_open", pr_number: 9})

      Runs.create_run!(%{
        kind: "implement",
        ref: "owner/fixture##{issue.number}",
        model: "sonnet",
        status: "succeeded",
        issue_id: issue.id
      })

      {:ok, view, _html} = live(conn, ~p"/issues")

      html =
        view
        |> element("a[href='/issues/#{issue.id}']", "Detail me")
        |> render_click()

      assert html =~ "issue-detail-modal"
      assert html =~ "implement"
      assert html =~ "succeeded"
    end

    test "navigating straight to /issues/:id renders the detail modal", %{conn: conn} do
      issue = issue_fixture(%{title: "Direct nav", pipeline_state: "plan_ready"})

      {:ok, _view, html} = live(conn, ~p"/issues/#{issue.id}")

      assert html =~ "issue-detail-modal"
      assert html =~ "Direct nav"
      assert html =~ "No runs yet."
    end

    test "adversarial review button enqueues ReviewWorker for an issue with an open PR", %{
      conn: conn
    } do
      issue =
        issue_fixture(%{
          title: "Review me",
          pipeline_state: "review_stalled",
          pr_number: 42
        })

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")

      view |> element("button", "Adversarial review") |> render_click()

      assert_enqueued(worker: Harness.GitHub.ReviewWorker, args: %{issue_id: issue.id})
    end

    test "bug-hunt and format buttons each enqueue a RespondWorker pass", %{conn: conn} do
      issue = issue_fixture(%{title: "Sweep me", pipeline_state: "pr_open", pr_number: 43})

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")

      view |> element("button", "Bug-hunt pass") |> render_click()
      view |> element("button", "Format pass") |> render_click()

      jobs = all_enqueued(worker: Harness.GitHub.RespondWorker)
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.args["issue_id"] == issue.id))
      assert Harness.Repo.aggregate(Harness.GitHub.PrCommentHandle, :count) == 2
    end

    test "issues without an open PR show no action buttons", %{conn: conn} do
      issue = issue_fixture(%{title: "No PR yet", pipeline_state: "plan_ready"})

      {:ok, _view, html} = live(conn, ~p"/issues/#{issue.id}")

      refute html =~ "Adversarial review"
      assert html =~ "no open PR"
    end

    test "posting a thread comment calls the GitHub client and flashes success", %{conn: conn} do
      issue = issue_fixture(%{title: "Thread me", pipeline_state: "pr_open", pr_number: 44})

      Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => 5001, "created_at" => "2026-07-06T10:00:00Z"})
      end)

      on_exit(fn -> Application.delete_env(:harness, :github_req_options) end)

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")

      html =
        view
        |> form("form[phx-submit='post_thread_comment']", %{"body" => "please tighten this up"})
        |> render_submit()

      assert html =~ "Comment posted"
    end
  end
end
