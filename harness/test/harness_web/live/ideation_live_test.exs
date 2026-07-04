defmodule HarnessWeb.IdeationLiveTest do
  use HarnessWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Harness.Ideation

  @moduletag :capture_log

  test "empty state invites seeding a session", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/ideation")
    assert html =~ "No sessions yet"
    assert html =~ "three hours"
  end

  test "starting a session navigates to its tree and enqueues an iteration", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ideation")

    view
    |> form("form", %{"seed_prompt" => "a calmer inbox", "budget_minutes" => "90"})
    |> render_submit()

    assert_patched(view, ~p"/ideation/1")
    assert render(view) =~ "Session #1"

    session = Ideation.get_session!(1)
    assert session.seed_prompt == "a calmer inbox"
    assert session.budget_minutes == 90
  end

  test "renders the tree with a node the user can select to read its artifact", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    child =
      Ideation.add_child!(
        session,
        root,
        %{title: "Bright Idea", summary: "s", score: 8.0},
        "# full artifact body"
      )

    {:ok, view, html} = live(conn, ~p"/ideation/#{session.id}")
    assert html =~ "Bright Idea"
    assert html =~ "<svg"

    html = view |> element("g[phx-value-id='#{child.id}']") |> render_click()
    assert html =~ "full artifact body"
  end

  test "pruned nodes are dimmed, not hidden", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})
    child = Ideation.add_child!(session, root, %{title: "Dead End", score: 2.0}, "")
    Ideation.mark_pruned!(child)

    {:ok, _view, html} = live(conn, ~p"/ideation/#{session.id}")
    assert html =~ "Dead End"
    assert html =~ ~s(opacity="0.3")
  end

  test "the operator can stop a running session", %{conn: conn} do
    {session, _root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    {:ok, view, _html} = live(conn, ~p"/ideation/#{session.id}")
    view |> element("button", "Stop") |> render_click()

    assert Ideation.get_session!(session.id).status == "stopped"
  end
end
