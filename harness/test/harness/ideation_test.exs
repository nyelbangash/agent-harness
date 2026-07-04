defmodule Harness.IdeationTest do
  use Harness.DataCase, async: false

  alias Harness.Ideation
  alias Harness.Ideation.Layout

  @moduletag :capture_log

  defp new_session(attrs \\ %{}) do
    {session, root} =
      Ideation.start_session(
        Map.merge(%{seed_prompt: "a better todo app", budget_minutes: 180}, attrs)
      )

    %{session: session, root: root}
  end

  describe "start_session/1" do
    test "creates the session, a frontier root, dirs, and enqueues an iteration" do
      %{session: session, root: root} = new_session()

      assert session.status == "running"
      assert root.depth == 0
      assert root.status == "frontier"
      assert File.dir?(Ideation.session_dir(session))
      assert Ideation.read_journal(session) =~ "a better todo app"
      assert_enqueued(worker: Ideation.IterationWorker, args: %{session_id: session.id})
    end
  end

  describe "add_child!/4 + tree" do
    test "persists children with artifacts on disk" do
      %{session: session, root: root} = new_session()

      child =
        Ideation.add_child!(
          session,
          root,
          %{title: "offline-first", summary: "sync later", score: 7.0},
          "# Offline\n\nfull thinking"
        )

      assert child.depth == 1
      assert child.parent_id == root.id
      assert File.read!(child.artifact_path) =~ "full thinking"
      assert Ideation.read_artifact(child) =~ "full thinking"
      assert length(Ideation.tree(session.id)) == 2
    end
  end

  describe "select_frontier/2 — the compounding heuristic" do
    test "prefers high score but decays with depth so it doesn't tunnel" do
      %{session: session, root: root} = new_session()

      # a deep, high-scoring node vs a shallow, slightly-lower one
      deep_parent = Ideation.add_child!(session, root, %{title: "d1", score: 6.0}, "")
      deep_parent = Ideation.add_child!(session, deep_parent, %{title: "d2", score: 6.0}, "")
      deep = Ideation.add_child!(session, deep_parent, %{title: "deep", score: 8.5}, "")
      Ideation.mark_expanded!(deep_parent)

      shallow = Ideation.add_child!(session, root, %{title: "shallow", score: 8.0}, "")
      Ideation.mark_expanded!(root)

      # decay 0.85^3 ≈ 0.614 → deep priority ≈ 5.2; shallow 0.85^1 = 6.8
      chosen = Ideation.select_frontier(session.id)
      assert chosen.id == shallow.id

      # but with no decay the deep high-scorer would win — proves decay matters
      all_frontier = Ideation.tree(session.id) |> Enum.filter(&(&1.status == "frontier"))
      best_raw = Enum.max_by(all_frontier, & &1.score)
      assert best_raw.id == deep.id
    end

    test "ignores pruned and expanded nodes; nil on empty frontier" do
      %{session: session, root: root} = new_session()
      Ideation.mark_expanded!(root)
      assert Ideation.select_frontier(session.id) == nil

      a = Ideation.add_child!(session, root, %{title: "a", score: 9.0}, "")
      Ideation.mark_pruned!(a)
      assert Ideation.select_frontier(session.id) == nil

      b = Ideation.add_child!(session, root, %{title: "b", score: 3.0}, "")
      assert Ideation.select_frontier(session.id).id == b.id
    end
  end

  describe "ancestor_chain + sibling_summaries" do
    test "chain runs root→node, siblings exclude self" do
      %{session: session, root: root} = new_session()
      mid = Ideation.add_child!(session, root, %{title: "mid", score: 6.0}, "")
      leaf = Ideation.add_child!(session, mid, %{title: "leaf", score: 6.0}, "")
      _sib = Ideation.add_child!(session, root, %{title: "aunt", score: 5.0}, "")

      chain = Ideation.ancestor_chain(leaf)
      assert Enum.map(chain, & &1.title) == ["Seed", "mid", "leaf"]

      assert Ideation.sibling_summaries(mid) |> Enum.any?(&(&1 =~ "aunt"))
      refute Ideation.sibling_summaries(mid) |> Enum.any?(&(&1 =~ "mid"))
    end
  end

  describe "journal" do
    test "entries are capped at 3 lines to prevent context bloat (§5.2)" do
      %{session: session} = new_session()
      Ideation.append_journal!(session, 1, ["one", "two", "three", "four", "five"])

      journal = Ideation.read_journal(session)
      assert journal =~ "one"
      assert journal =~ "three"
      refute journal =~ "four"
    end
  end

  describe "Layout.compute/1" do
    test "positions nodes by depth and centers parents over children" do
      %{session: session, root: root} = new_session()
      a = Ideation.add_child!(session, root, %{title: "a", score: 6.0}, "")
      b = Ideation.add_child!(session, root, %{title: "b", score: 6.0}, "")

      layout = Layout.compute(Ideation.tree(session.id))
      nodes = Map.new(layout.nodes, &{&1.id, &1})

      # children on a deeper row than the root
      assert nodes[a.id].y > nodes[root.id].y
      assert nodes[a.id].y == nodes[b.id].y
      # root centered between its two children
      assert_in_delta nodes[root.id].x, (nodes[a.id].x + nodes[b.id].x) / 2, 0.1
      # one edge per parent-child link
      assert length(layout.edges) == 2
    end
  end
end
