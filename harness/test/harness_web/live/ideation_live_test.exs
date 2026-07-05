defmodule HarnessWeb.IdeationLiveTest do
  use HarnessWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Harness.Ideation

  @moduletag :capture_log

  test "empty state shows the loop diagram and sample seeds", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/ideation")
    assert html =~ "How ideation works"
    assert html =~ "diverge"
    assert html =~ "synthesize"
    assert html =~ "Try a sample idea"
    assert html =~ "false positives"
  end

  test "start button is inside the aside form, not overflowing into the section", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ideation")
    # button must live inside the aside's form, not in the right-hand section
    assert has_element?(view, "aside form button", "Start")
    # explainer lives in the section, not the aside
    assert has_element?(view, "section h2", "How ideation works")
    refute has_element?(view, "section button", "Start")
  end

  test "clicking a sample seed prefills the seed form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ideation")
    seed = "A smarter PR triage that learns from past false positives"
    html = view |> element("button[phx-value-seed='#{seed}']") |> render_click()
    assert html =~ "false positives"
  end

  test "composer shows 'starts immediately' inside ideation window", %{conn: conn} do
    # 22:00 is inside the fixture policy's 21:00-02:00 ideation window
    {:ok, _view, html} =
      conn
      |> put_connect_params(%{"test_now" => "22:00"})
      |> live(~p"/ideation")

    assert html =~ "starts immediately"
  end

  test "composer shows start time when outside ideation window", %{conn: conn} do
    # 12:00 is outside 21:00-02:00; next window opens at 21:00 (9 h away)
    {:ok, _view, html} =
      conn
      |> put_connect_params(%{"test_now" => "12:00"})
      |> live(~p"/ideation")

    assert html =~ "will start at 21:00"
  end

  test "starting a session navigates to its tree and enqueues an iteration", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ideation")

    view
    |> form("form", %{"seed_prompt" => "a calmer inbox", "budget_minutes" => "90"})
    |> render_submit()

    assert_patched(view, ~p"/ideation/1")
    assert render(view) =~ "Session #1"
    # composer clears for the next seed
    refute render(view) =~ "a calmer inbox</textarea>"

    # clicking the selected session again deselects it
    view |> element("a", "a calmer inbox") |> render_click()
    assert_patched(view, ~p"/ideation")
    refute render(view) =~ "Session #1</h1>"

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
    # the tree carries the pan/zoom hook and the server viewBox for reset
    assert html =~ "TreeZoom"
    assert html =~ "data-viewbox"

    html = view |> element("g[phx-value-id='#{child.id}']") |> render_click()
    assert html =~ "full artifact body"
  end

  test "clicking a node opens a rendered-markdown modal, escape closes it", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    child =
      Ideation.add_child!(
        session,
        root,
        %{title: "Formatted", summary: "s", score: 8.0},
        "## Section head\n\n- bullet one\n- **bold** point"
      )

    {:ok, view, _html} = live(conn, ~p"/ideation/#{session.id}")

    html = view |> element("g[phx-value-id='#{child.id}']") |> render_click()
    assert html =~ ~s(id="artifact-modal")
    assert html =~ "<h2>"
    assert html =~ "<li>"
    assert html =~ "<strong>bold</strong>"
    refute html =~ "## Section head"

    html = render_keydown(element(view, "#artifact-modal"), %{"key" => "escape"})
    refute html =~ ~s(id="artifact-modal")
  end

  test "modal for a mid-tree node shows its ancestor breadcrumb and children list", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    parent =
      Ideation.add_child!(session, root, %{title: "Parent Node", summary: "p", score: 7.0},
        "# parent body"
      )

    child =
      Ideation.add_child!(session, parent, %{title: "Child Node", summary: "c", score: 6.0},
        "# child body"
      )

    _leaf =
      Ideation.add_child!(session, child, %{title: "Grandchild", summary: "g", score: 5.0},
        "# grand body"
      )

    {:ok, view, _html} = live(conn, ~p"/ideation/#{session.id}")
    html = view |> element("g[phx-value-id='#{child.id}']") |> render_click()

    # breadcrumb shows ancestors (root and parent, not the current node)
    assert html =~ "Seed"
    assert html =~ "Parent Node"

    # children section lists the grandchild
    assert html =~ "Grandchild"
  end

  test "arrow keydown moves between siblings", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    sib_a =
      Ideation.add_child!(session, root, %{title: "Sibling A", summary: "a", score: 6.0},
        "# artifact a"
      )

    _sib_b =
      Ideation.add_child!(session, root, %{title: "Sibling B", summary: "b", score: 5.0},
        "# artifact b"
      )

    {:ok, view, _html} = live(conn, ~p"/ideation/#{session.id}")
    view |> element("g[phx-value-id='#{sib_a.id}']") |> render_click()

    # arrow right moves to Sibling B
    html = render_keydown(element(view, "#artifact-modal"), %{"key" => "ArrowRight"})
    assert html =~ "artifact b"
    refute html =~ "artifact a"
  end

  test "breadcrumb click swaps modal to the ancestor node", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    parent =
      Ideation.add_child!(session, root, %{title: "Mid Node", summary: "m", score: 7.0},
        "# mid artifact"
      )

    leaf =
      Ideation.add_child!(session, parent, %{title: "Leaf Node", summary: "l", score: 6.0},
        "# leaf artifact"
      )

    {:ok, view, _html} = live(conn, ~p"/ideation/#{session.id}")
    view |> element("g[phx-value-id='#{leaf.id}']") |> render_click()

    # breadcrumb contains a button for the parent; click it
    html = view |> element("button[phx-value-id='#{parent.id}']") |> render_click()
    assert html =~ "mid artifact"
    refute html =~ "leaf artifact"
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
