defmodule Harness.Ideation.WorkersTest do
  use Harness.DataCase, async: false

  alias Harness.Ideation
  alias Harness.Ideation.{CritiqueWorker, IterationWorker}
  alias Harness.Runs.FakeRunner

  @moduletag :capture_log

  defp diverge_output(children) do
    %{"children" => children, "journal" => ["tried some branches", "one surprised me"]}
  end

  setup do
    enable_ideation!()
    :ok
  end

  defp start do
    {session, root} = Ideation.start_session(%{seed_prompt: "seed idea", budget_minutes: 180})
    Harness.Repo.delete_all(Oban.Job)
    %{session: session, root: root}
  end

  test "a diverge iteration branches the frontier and enqueues the next", %{} = _ do
    %{session: session} = start()

    FakeRunner.script([
      {:ok,
       Harness.Fixtures.runner_result(
         structured_output:
           diverge_output([
             %{"title" => "branch A", "summary" => "a", "score" => 7.0, "artifact" => "deep A"},
             %{"title" => "branch B", "summary" => "b", "score" => 6.0, "artifact" => "deep B"}
           ])
       )}
    ])

    assert :ok = perform_job(IterationWorker, %{session_id: session.id})

    tree = Ideation.tree(session.id)
    assert length(tree) == 3
    assert Enum.any?(tree, &(&1.title == "branch A"))
    assert Enum.any?(tree, &(&1.status == "expanded"))

    session = Ideation.get_session!(session.id)
    assert session.iterations == 1
    assert session.no_progress_streak == 0

    # the iteration prompt included the seed verbatim (anti-drift)
    [spec] = FakeRunner.executed_specs()
    assert spec.kind == :ideate
    assert spec.prompt =~ "seed idea"
    assert_enqueued(worker: IterationWorker, args: %{session_id: session.id})
  end

  test "every critique_every iterations a critique runs instead of an iteration" do
    %{session: session} = start()
    # policy fixture: critique_every = 5. Advance to iteration 4 already done.
    Ideation.update_session!(session, %{iterations: 4})

    FakeRunner.script([
      {:ok,
       Harness.Fixtures.runner_result(
         structured_output:
           diverge_output([
             %{"title" => "c", "summary" => "c", "score" => 6.0, "artifact" => "x"},
             %{"title" => "d", "summary" => "d", "score" => 6.0, "artifact" => "y"}
           ])
       )}
    ])

    assert :ok = perform_job(IterationWorker, %{session_id: session.id})

    # iteration 5 → critique, not another iteration
    assert_enqueued(worker: CritiqueWorker, args: %{session_id: session.id})
    refute_enqueued(worker: IterationWorker)
  end

  test "budget exhaustion stops the session and enqueues final synthesis" do
    {session, _root} =
      Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 1})

    Harness.Repo.delete_all(Oban.Job)
    # backdate the start so the 1-minute budget is blown
    Ideation.update_session!(session, %{
      started_at: DateTime.add(DateTime.utc_now(), -120, :second),
      iterations: 1
    })

    FakeRunner.script([])
    assert :ok = perform_job(IterationWorker, %{session_id: session.id})

    session = Ideation.get_session!(session.id)
    assert session.status == "stopped"
    assert session.stop_reason == "budget_exhausted"
    assert_enqueued(worker: CritiqueWorker, args: %{session_id: session.id, final: true})
    assert FakeRunner.executed_specs() == []
  end

  test "critique re-scores, prunes, and TWO consecutive critiques stop the run" do
    %{session: session, root: root} = start()
    a = Ideation.add_child!(session, root, %{title: "weak", score: 6.0}, "")
    b = Ideation.add_child!(session, root, %{title: "strong", score: 6.0}, "")
    # one prior no-progress critique already recorded
    Ideation.update_session!(session, %{iterations: 5, critique_no_progress_streak: 1})

    FakeRunner.script([
      {:ok,
       Harness.Fixtures.runner_result(
         structured_output: %{
           "rescored" => [
             %{"idea_id" => a.id, "score" => 2.0, "prune" => true},
             %{"idea_id" => b.id, "score" => 9.0, "prune" => false}
           ],
           "drift" => false,
           "material_progress" => false,
           "note" => "converging on the strong branch"
         }
       )}
    ])

    assert :ok = perform_job(CritiqueWorker, %{session_id: session.id})

    assert Ideation.get_idea!(a.id).status == "pruned"
    assert Ideation.get_idea!(a.id).score == 2.0
    assert Ideation.get_idea!(b.id).score == 9.0

    session = Ideation.get_session!(session.id)
    assert session.critiques == 1
    # second consecutive no-progress CRITIQUE → the next IterationWorker stops
    assert session.critique_no_progress_streak == 2

    FakeRunner.script([])
    assert :ok = perform_job(IterationWorker, %{session_id: session.id})
    assert Ideation.get_session!(session.id).stop_reason == "no_material_progress"
  end

  test "malformed iterations alone do NOT stop the session (only critiques do)" do
    %{session: session} = start()
    Ideation.update_session!(session, %{iterations: 1})

    # two consecutive malformed-output iterations
    FakeRunner.script([
      {:ok, Harness.Fixtures.runner_result(structured_output: %{"garbage" => 1})}
    ])

    assert :ok = perform_job(IterationWorker, %{session_id: session.id})

    FakeRunner.script([
      {:ok, Harness.Fixtures.runner_result(structured_output: %{"garbage" => 2})}
    ])

    assert :ok = perform_job(IterationWorker, %{session_id: session.id})

    # still running — the stop condition is critique-driven, not iteration-driven
    session = Ideation.get_session!(session.id)
    assert session.status == "running"
    assert session.no_progress_streak == 2
    assert session.critique_no_progress_streak == 0
  end

  test "a transient utilization defer snoozes the iteration, never kills the session" do
    %{session: session} = start()

    # age out the fresh usage sample so current_mode fails closed to plan_only
    # → gate(:ideate) returns {:skip, :usage_defers_ideation}
    Harness.Repo.update_all(Harness.Usage.Sample,
      set: [sampled_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
    )

    FakeRunner.script([])
    assert {:snooze, _} = perform_job(IterationWorker, %{session_id: session.id})

    # the session is untouched — NOT stopped, no premature synthesis
    session = Ideation.get_session!(session.id)
    assert session.status == "running"
    refute_enqueued(worker: CritiqueWorker)
  end

  test "a critique queued for a stopped session cancels instead of spending Opus" do
    %{session: session} = start()
    Ideation.stop_session!(session, :operator)

    FakeRunner.script([])

    assert {:cancel, :session_not_running} =
             perform_job(CritiqueWorker, %{session_id: session.id})

    assert FakeRunner.executed_specs() == []
  end

  test "final synthesis writes SYNTHESIS.md and marks the session synthesized" do
    %{session: session} = start()
    Ideation.stop_session!(session, :budget_exhausted)

    FakeRunner.script([
      fn spec ->
        File.write!(Path.join(spec.cwd, "SYNTHESIS.md"), "# Synthesis\n\nthe strongest branches…")
        {:ok, Harness.Fixtures.runner_result()}
      end
    ])

    assert :ok = perform_job(CritiqueWorker, %{session_id: session.id, final: true})

    session = Ideation.get_session!(session.id)
    assert session.status == "synthesized"
    assert File.read!(session.synthesis_path) =~ "strongest branches"
  end

  test "a killed iteration cancels rather than retrying a fresh session" do
    %{session: session} = start()
    FakeRunner.script([{:error, :killed}])

    assert {:cancel, :killed} = perform_job(IterationWorker, %{session_id: session.id})
  end

  test "a stored nudge appears in the iteration prompt exactly once then is cleared" do
    %{session: session} = start()
    session = Ideation.set_nudge!(session, "explore the async angle")

    FakeRunner.script([
      {:ok,
       Harness.Fixtures.runner_result(
         structured_output:
           diverge_output([
             %{"title" => "branch A", "summary" => "a", "score" => 7.0, "artifact" => "x"},
             %{"title" => "branch B", "summary" => "b", "score" => 6.0, "artifact" => "y"}
           ])
       )}
    ])

    assert :ok = perform_job(IterationWorker, %{session_id: session.id})

    [spec] = FakeRunner.executed_specs()
    assert spec.prompt =~ "explore the async angle"

    # nudge is consumed — cleared from session after the iteration
    session = Ideation.get_session!(session.id)
    assert is_nil(session.nudge)

    # second iteration: nudge no longer present in prompt
    FakeRunner.script([
      {:ok,
       Harness.Fixtures.runner_result(
         structured_output: %{
           "title" => "a-developed",
           "summary" => "deeper",
           "score" => 7.5,
           "artifact" => "developed artifact",
           "journal" => ["went deeper"]
         }
       )}
    ])

    assert :ok = perform_job(IterationWorker, %{session_id: session.id})
    [spec2] = FakeRunner.executed_specs()
    # the dedicated nudge section must not appear; the nudge may linger in the journal as history
    refute spec2.prompt =~ "## Operator nudge"
  end

  test "a focused node is chosen regardless of frontier score" do
    %{session: session, root: root} = start()

    # two frontier children: one high-scorer that would normally win,
    # one low-scorer that the operator explicitly focuses
    _high = Ideation.add_child!(session, root, %{title: "high-scorer", score: 9.0}, "")
    low = Ideation.add_child!(session, root, %{title: "low-focus", score: 2.0}, "")

    session = Ideation.focus_node!(session, low.id)

    FakeRunner.script([
      {:ok,
       Harness.Fixtures.runner_result(
         structured_output: %{
           "title" => "developed low",
           "summary" => "focused branch developed",
           "score" => 4.0,
           "artifact" => "focused content",
           "journal" => ["followed operator focus"]
         }
       )}
    ])

    assert :ok = perform_job(IterationWorker, %{session_id: session.id})

    [spec] = FakeRunner.executed_specs()
    # the prompt was built for the focused (low-score) node, not the high-scorer
    assert spec.prompt =~ "low-focus"

    # focus cleared after one use
    session = Ideation.get_session!(session.id)
    assert is_nil(session.focus_node_id)
  end

  test "synthesize_now! stops the session and enqueues synthesis with operator_synthesis stop_reason" do
    %{session: session} = start()

    Ideation.synthesize_now!(session)

    session = Ideation.get_session!(session.id)
    assert session.status == "stopped"
    assert session.stop_reason == "operator_synthesis"
    assert_enqueued(worker: CritiqueWorker, args: %{session_id: session.id, final: true})

    # running the final synthesis marks it synthesized with the operator_synthesis reason
    FakeRunner.script([
      fn spec ->
        File.write!(Path.join(spec.cwd, "SYNTHESIS.md"), "# Synthesis\n\noperator triggered")
        {:ok, Harness.Fixtures.runner_result()}
      end
    ])

    assert :ok = perform_job(CritiqueWorker, %{session_id: session.id, final: true})

    session = Ideation.get_session!(session.id)
    assert session.status == "synthesized"
    assert session.stop_reason == "operator_synthesis"
  end
end
