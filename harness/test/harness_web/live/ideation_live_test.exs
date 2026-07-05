defmodule HarnessWeb.IdeationLiveTest do
  use HarnessWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Harness.Ideation
  alias Harness.Ideation.Layout

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
      Ideation.add_child!(
        session,
        root,
        %{title: "Parent Node", summary: "p", score: 7.0},
        "# parent body"
      )

    child =
      Ideation.add_child!(
        session,
        parent,
        %{title: "Child Node", summary: "c", score: 6.0},
        "# child body"
      )

    _leaf =
      Ideation.add_child!(
        session,
        child,
        %{title: "Grandchild", summary: "g", score: 5.0},
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
      Ideation.add_child!(
        session,
        root,
        %{title: "Sibling A", summary: "a", score: 6.0},
        "# artifact a"
      )

    _sib_b =
      Ideation.add_child!(
        session,
        root,
        %{title: "Sibling B", summary: "b", score: 5.0},
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
      Ideation.add_child!(
        session,
        root,
        %{title: "Mid Node", summary: "m", score: 7.0},
        "# mid artifact"
      )

    leaf =
      Ideation.add_child!(
        session,
        parent,
        %{title: "Leaf Node", summary: "l", score: 6.0},
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

  test "status line renders iteration and critique counts", %{conn: conn} do
    {session, _root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 60})
    Ideation.update_session!(session, %{iterations: 7, critiques: 2})

    {:ok, _view, html} = live(conn, ~p"/ideation/#{session.id}")

    assert html =~ "iteration 7"
    assert html =~ "critique 2/"
    assert html =~ "60"
  end

  test "broadcasting a developing_node marks that node with a data-developing attr", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 60})
    {:ok, view, html} = live(conn, ~p"/ideation/#{session.id}")
    refute html =~ ~s(data-developing="true")

    send(view.pid, {:developing_node, root.id})

    html = render(view)
    assert html =~ ~s(data-developing="true")

    # a session_updated clears the pulse
    send(view.pid, {:session_updated, Ideation.get_session!(session.id)})
    refute render(view) =~ ~s(data-developing="true")
  end

  test "broadcasting critique_running shows the critique indicator", %{conn: conn} do
    {session, _root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 60})
    {:ok, view, html} = live(conn, ~p"/ideation/#{session.id}")
    refute html =~ "critique in progress"

    send(view.pid, {:critique_running, session.id})

    assert render(view) =~ "critique in progress"

    # cleared when session updates
    send(view.pid, {:session_updated, Ideation.get_session!(session.id)})
    refute render(view) =~ "critique in progress"
  end

  test "viewBox hugs content bounds for a seeded tree", %{conn: conn} do
    {session, _root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 60})
    ideas = Ideation.tree(session.id)
    layout = Layout.compute(ideas)

    {:ok, _view, html} = live(conn, ~p"/ideation/#{session.id}")

    assert html =~ ~s(viewBox="0 0 #{layout.width} #{layout.height}")
    assert html =~ ~s(data-viewbox="0 0 #{layout.width} #{layout.height}")
  end

  test "idle inspector shows top-scored nodes in score order", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    _low =
      Ideation.add_child!(session, root, %{title: "Low Scorer", summary: "l", score: 2.0},
        "# low body")

    _high =
      Ideation.add_child!(session, root, %{title: "High Scorer", summary: "h", score: 9.0},
        "# high body")

    _mid =
      Ideation.add_child!(session, root, %{title: "Mid Scorer", summary: "m", score: 6.0},
        "# mid body")

    {:ok, _view, html} = live(conn, ~p"/ideation/#{session.id}")

    assert html =~ "Top nodes"
    assert html =~ "High Scorer"
    assert html =~ "Low Scorer"

    # Check order within the leaderboard (after the "Top nodes" heading)
    {cockpit_start, _} = :binary.match(html, "Top nodes")
    cockpit_tail = binary_part(html, cockpit_start, byte_size(html) - cockpit_start)
    {high_pos, _} = :binary.match(cockpit_tail, "High Scorer")
    {low_pos, _} = :binary.match(cockpit_tail, "Low Scorer")
    assert high_pos < low_pos
  end

  test "clicking a leaderboard row fires select_node and shows the node artifact", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    high =
      Ideation.add_child!(session, root, %{title: "Best Idea", summary: "h", score: 9.0},
        "# best artifact body")

    {:ok, view, html} = live(conn, ~p"/ideation/#{session.id}")

    assert html =~ "Top nodes"

    html = view |> element("button[phx-value-id='#{high.id}']") |> render_click()
    assert html =~ "best artifact body"
    assert html =~ "Best Idea"
  end

  test "journal renders two iterations newest-first as cards with rendered markdown", %{
    conn: conn
  } do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    _child =
      Ideation.add_child!(session, root, %{title: "Alpha Node", summary: "s", score: 7.0},
        "# alpha")

    Ideation.append_journal!(session, 1, ["explored **Alpha Node** idea"])
    Ideation.append_journal!(session, 2, ["pruned Alpha Node after review"])

    {:ok, _view, html} = live(conn, ~p"/ideation/#{session.id}")

    # Both iteration labels are present
    assert html =~ "Iteration 1"
    assert html =~ "Iteration 2"

    # Markdown rendered — bold becomes <strong>, raw ** should not appear
    assert html =~ "<strong>"
    refute html =~ "**Alpha Node**"

    # Newest-first: Iteration 2 appears before Iteration 1 in the document
    {pos2, _} = :binary.match(html, "Iteration 2")
    {pos1, _} = :binary.match(html, "Iteration 1")
    assert pos2 < pos1
  end

  test "journal node-title link fires select_node and opens the artifact", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    child =
      Ideation.add_child!(session, root, %{title: "Beta Node", summary: "s", score: 7.0},
        "# beta artifact body")

    Ideation.append_journal!(session, 1, ["explored Beta Node in depth"])

    {:ok, view, html} = live(conn, ~p"/ideation/#{session.id}")

    # The node title in the journal is a phx-click button
    assert html =~ ~s(phx-value-id="#{child.id}")
    assert html =~ ~s(journal-node-link)

    # Clicking the journal link selects the node and shows its artifact
    html =
      view
      |> element("button.journal-node-link[phx-value-id='#{child.id}']")
      |> render_click()

    assert html =~ "beta artifact body"
  end

  test "tree svg has data-zoom-level attribute and semantic-zoom label/badge elements", %{
    conn: conn
  } do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 60})
    _child = Ideation.add_child!(session, root, %{title: "Some Idea", summary: "detail", score: 7.0}, "")
    {:ok, _view, html} = live(conn, ~p"/ideation/#{session.id}")

    # SVG carries the data-zoom-level attribute the hook maintains
    assert html =~ ~s(data-zoom-level=)
    # Label text elements have the CSS-targetable class
    assert html =~ ~s(class="font-mono tree-label")
    # Score badge elements exist for the zoomed-in level
    assert html =~ ~s(class="font-mono tree-score")
  end

  test "tree search marks matching nodes with data-match and dims non-matching ones", %{
    conn: conn
  } do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    _match =
      Ideation.add_child!(session, root, %{title: "Bright Idea", summary: "s", score: 8.0}, "")

    _no_match =
      Ideation.add_child!(session, root, %{title: "Dark Thought", summary: "s", score: 5.0}, "")

    {:ok, view, html} = live(conn, ~p"/ideation/#{session.id}")
    # no search active — data-match absent
    refute html =~ ~s(data-match=)

    html = view |> form("#tree-search-form") |> render_change(%{"q" => "bright"})
    assert html =~ ~s(data-match="true")
    assert html =~ ~s(data-match="false")

    # clearing the search removes data-match marks
    html = view |> form("#tree-search-form") |> render_change(%{"q" => ""})
    refute html =~ ~s(data-match=)
  end

  test "promote button visible on high-scoring nodes when policy has repos", %{conn: conn} do
    # add a repo to policy so the promote button renders
    original = Application.fetch_env!(:harness, :policy_path)
    tmp = Path.join(System.tmp_dir!(), "promote-ui-policy-#{System.unique_integer([:positive])}.yaml")

    File.write!(
      tmp,
      File.read!(original) |> String.replace("repos: []", "repos:\n  - owner/repo")
    )

    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
    end)

    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    high =
      Ideation.add_child!(session, root, %{title: "Top Idea", summary: "s", score: 8.0},
        "# artifact")

    {:ok, view, _html} = live(conn, ~p"/ideation/#{session.id}")
    html = view |> element("g[phx-value-id='#{high.id}']") |> render_click()

    assert html =~ "Promote"
  end

  test "promote button absent when no policy repos configured", %{conn: conn} do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    high =
      Ideation.add_child!(session, root, %{title: "Top Idea", summary: "s", score: 9.0},
        "# artifact")

    {:ok, view, _html} = live(conn, ~p"/ideation/#{session.id}")
    html = view |> element("g[phx-value-id='#{high.id}']") |> render_click()

    refute html =~ "Promote"
  end

  test "promote modal opens on promote click and enqueues job", %{conn: conn} do
    original = Application.fetch_env!(:harness, :policy_path)
    tmp = Path.join(System.tmp_dir!(), "promote-modal-policy-#{System.unique_integer([:positive])}.yaml")

    File.write!(
      tmp,
      File.read!(original) |> String.replace("repos: []", "repos:\n  - owner/testrepo")
    )

    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
    end)

    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 180})

    idea =
      Ideation.add_child!(session, root, %{title: "Promotable", summary: "s", score: 8.5},
        "# artifact")

    {:ok, view, _html} = live(conn, ~p"/ideation/#{session.id}")
    view |> element("g[phx-value-id='#{idea.id}']") |> render_click()

    # click Promote button
    html = view |> element("button", "Promote") |> render_click()
    assert html =~ "promote-modal"
    assert html =~ "owner/testrepo"

    # submit the form
    html =
      view
      |> form("#promote-modal form", %{"target_repo" => "owner/testrepo"})
      |> render_submit()

    refute html =~ "promote-modal"
    assert html =~ "Promoting to owner/testrepo"
  end

  test "viewBox height adjusts with tree depth, hugging content tighter than the old formula", %{
    conn: conn
  } do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 60})
    _child = Ideation.add_child!(session, root, %{title: "Child", summary: "s", score: 7.0}, "")

    ideas = Ideation.tree(session.id)
    layout = Layout.compute(ideas)

    # root at depth 0 (y=40), child at depth 1 (y=130); content height = 130 + margin(40) = 170
    # the old formula gave @margin*2 + 1*@y_gap + 40 = 210 — 40 units tighter now
    assert layout.height == 170
    assert layout.height < 210

    {:ok, _view, html} = live(conn, ~p"/ideation/#{session.id}")
    assert html =~ ~s(viewBox="0 0 #{layout.width} #{layout.height}")
  end
end
