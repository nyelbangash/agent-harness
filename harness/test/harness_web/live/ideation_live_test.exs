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

  test "tree SVG has semantic zoom structure: initial zoom level and CSS classes on nodes", %{
    conn: conn
  } do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})
    Ideation.add_child!(session, root, %{title: "Test Node", summary: "detail", score: 7.0}, "")

    {:ok, _view, html} = live(conn, ~p"/ideation/#{session.id}")

    assert html =~ ~s(data-zoom-level="labels")
    assert html =~ ~s(class="node-label)
    assert html =~ ~s(class="node-badge)
  end

  test "search dims non-matching nodes and marks matching ones", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    child1 =
      Ideation.add_child!(
        session,
        root,
        %{title: "Bright Idea", summary: "luminous thinking", score: 8.0},
        ""
      )

    _child2 =
      Ideation.add_child!(
        session,
        root,
        %{title: "Dim Thought", summary: "nothing special", score: 4.0},
        ""
      )

    {:ok, view, _html} = live(conn, ~p"/ideation/#{session.id}")

    view |> form("form[phx-change='search_nodes']", %{"q" => "Bright"}) |> render_change()

    assert has_element?(view, "g[data-search-match='true'][phx-value-id='#{child1.id}']")
    assert has_element?(view, "g[data-search-match='false']")
  end

  test "search Enter selects first matching node", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    _child =
      Ideation.add_child!(
        session,
        root,
        %{title: "Matchable Node", summary: "s", score: 8.0},
        "artifact content here"
      )

    {:ok, view, _html} = live(conn, ~p"/ideation/#{session.id}")

    view |> form("form[phx-change='search_nodes']", %{"q" => "Matchable"}) |> render_change()
    render_keydown(element(view, "input[phx-keydown='search_select']"), %{"key" => "Enter"})

    assert has_element?(view, "#artifact-modal")
  end

  test "search summary match dims non-matching nodes", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    child =
      Ideation.add_child!(
        session,
        root,
        %{title: "Plain Title", summary: "unique_summary_keyword", score: 7.0},
        ""
      )

    _other =
      Ideation.add_child!(
        session,
        root,
        %{title: "Other Node", summary: "completely different", score: 5.0},
        ""
      )

    {:ok, view, _html} = live(conn, ~p"/ideation/#{session.id}")

    view
    |> form("form[phx-change='search_nodes']", %{"q" => "unique_summary_keyword"})
    |> render_change()

    assert has_element?(view, "g[data-search-match='true'][phx-value-id='#{child.id}']")
    assert has_element?(view, "g[data-search-match='false']")
  end
end
