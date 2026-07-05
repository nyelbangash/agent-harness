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

  test "stored nudge appears in the next iteration prompt exactly once, then is consumed" do
    %{session: session} = start()
    Ideation.set_nudge!(session, "explore cost reduction angles")

    FakeRunner.script([
      {:ok,
       Harness.Fixtures.runner_result(
         structured_output:
           diverge_output([
             %{"title" => "x", "summary" => "x", "score" => 7.0, "artifact" => "x"},
             %{"title" => "y", "summary" => "y", "score" => 6.0, "artifact" => "y"}
           ])
       )}
    ])

    assert :ok = perform_job(IterationWorker, %{session_id: session.id})

    [spec] = FakeRunner.executed_specs()
    # The nudge section header must appear in the first prompt
    assert spec.prompt =~ "## Operator nudge", "nudge section must appear in first prompt"
    assert spec.prompt =~ "explore cost reduction angles", "nudge text must appear in first prompt"

    session = Ideation.get_session!(session.id)
    assert is_nil(session.nudge), "nudge must be cleared from session after first use"

    # second iteration — the nudge SECTION must not be rendered (the journal may
    # still contain the logged line, but the instruction block itself is gone)
    FakeRunner.script([
      {:ok,
       Harness.Fixtures.runner_result(
         structured_output: %{
           "title" => "x refined",
           "summary" => "refined",
           "score" => 7.0,
           "artifact" => "deeper artifact",
           "journal" => ["dug deeper into x"]
         }
       )}
    ])

    assert :ok = perform_job(IterationWorker, %{session_id: session.id})

    [spec2] = FakeRunner.executed_specs()
    refute spec2.prompt =~ "## Operator nudge", "nudge section must not appear in second prompt"
  end

  test "focused node is chosen regardless of score, then forced_node_id is cleared" do
    %{session: session, root: root} = start()

    # low_score is at depth 1 (odd → develop mode); script a develop response
    low_score = Ideation.add_child!(session, root, %{title: "low-score", score: 2.0}, "")
    _high_score = Ideation.add_child!(session, root, %{title: "high-score", score: 9.0}, "")

    Ideation.set_forced_node!(session, low_score.id)

    FakeRunner.script([
      {:ok,
       Harness.Fixtures.runner_result(
         structured_output: %{
           "title" => "low-score refined",
           "summary" => "developed",
           "score" => 3.0,
           "artifact" => "refined artifact",
           "journal" => ["operator focus applied"]
         }
       )}
    ])

    assert :ok = perform_job(IterationWorker, %{session_id: session.id})

    # The low-score node was forced even though high-score had much higher priority
    assert Ideation.get_idea!(low_score.id).status == "expanded",
           "forced node must be marked expanded after iteration"

    session = Ideation.get_session!(session.id)
    assert is_nil(session.forced_node_id), "forced_node_id must be cleared after use"
  end

  test "synthesize_now stops with operator_synthesis reason and produces synthesis" do
    %{session: session, root: root} = start()
    Ideation.add_child!(session, root, %{title: "branch", score: 7.0}, "artifact text")

    Ideation.stop_session!(session, :operator_synthesis)

    session = Ideation.get_session!(session.id)
    assert session.status == "stopped"
    assert session.stop_reason == "operator_synthesis"

    assert_enqueued(worker: CritiqueWorker, args: %{session_id: session.id, final: true})

    FakeRunner.script([
      fn spec ->
        File.write!(Path.join(spec.cwd, "SYNTHESIS.md"), "# Synthesis\n\noperator-triggered")
        {:ok, Harness.Fixtures.runner_result()}
      end
    ])

    assert :ok = perform_job(CritiqueWorker, %{session_id: session.id, final: true})

    session = Ideation.get_session!(session.id)
    assert session.status == "synthesized"
    assert File.read!(session.synthesis_path) =~ "operator-triggered"
  end

  test "no write tools are exposed to ideation iteration runs" do
    %{session: session} = start()

    FakeRunner.script([
      {:ok,
       Harness.Fixtures.runner_result(
         structured_output:
           diverge_output([
             %{"title" => "a", "summary" => "a", "score" => 7.0, "artifact" => "x"},
             %{"title" => "b", "summary" => "b", "score" => 6.0, "artifact" => "y"}
           ])
       )}
    ])

    assert :ok = perform_job(IterationWorker, %{session_id: session.id})

    [spec] = FakeRunner.executed_specs()
    write_tools = ~w(Write Edit)
    bash_writes = Enum.filter(spec.allowed_tools, &String.starts_with?(&1, "Bash"))

    assert Enum.empty?(Enum.filter(spec.allowed_tools, &(&1 in write_tools))),
           "write tools must not be exposed to ideation: #{inspect(spec.allowed_tools)}"

    assert Enum.empty?(bash_writes),
           "Bash tools must not be exposed to ideation: #{inspect(spec.allowed_tools)}"
  end

  describe "repo grounding" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "ideation-grounding-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      repo = "testorg/testrepo"
      create_git_remote!(tmp, repo)
      Application.put_env(:harness, :github_remote_base, "file://#{tmp}/")

      # Add the repo to the active policy so detect_referenced_repos finds it
      policy_path = Application.fetch_env!(:harness, :policy_path)
      original_content = File.read!(policy_path)
      updated = String.replace(original_content, "repos: []", "repos:\n  - \"#{repo}\"")
      File.write!(policy_path, updated)
      Harness.Policy.reload()

      on_exit(fn ->
        Application.delete_env(:harness, :github_remote_base)
        # Restore original policy content before the standard enable_ideation!
        # on_exit runs (which also cleans up the temp file).
        File.write!(policy_path, original_content)
        Harness.Policy.reload()
        File.rm_rf!(tmp)
      end)

      %{tmp: tmp, repo: repo}
    end

    test "seed mentioning a policy repo (full owner/name) yields prompt with checkout path",
         %{repo: repo} do
      {session, _root} =
        Ideation.start_session(%{
          seed_prompt: "rethink the gauge cluster in #{repo}",
          budget_minutes: 180
        })

      Harness.Repo.delete_all(Oban.Job)

      FakeRunner.script([
        {:ok,
         Harness.Fixtures.runner_result(
           structured_output:
             diverge_output([
               %{"title" => "x", "summary" => "x", "score" => 7.0, "artifact" => "x"},
               %{"title" => "y", "summary" => "y", "score" => 6.0, "artifact" => "y"}
             ])
         )}
      ])

      assert :ok = perform_job(IterationWorker, %{session_id: session.id})

      [spec] = FakeRunner.executed_specs()
      home = Application.fetch_env!(:harness, :harness_home)
      expected_path = Path.join([home, "repos", String.replace(repo, "/", "--")])
      assert spec.prompt =~ expected_path, "prompt must contain checkout path for #{repo}"
    end

    test "seed mentioning a policy repo by bare name yields prompt with checkout path",
         %{repo: repo} do
      bare = repo |> String.split("/") |> List.last()

      {session, _root} =
        Ideation.start_session(%{
          seed_prompt: "improve the #{bare} module architecture",
          budget_minutes: 180
        })

      Harness.Repo.delete_all(Oban.Job)

      FakeRunner.script([
        {:ok,
         Harness.Fixtures.runner_result(
           structured_output:
             diverge_output([
               %{"title" => "x", "summary" => "x", "score" => 7.0, "artifact" => "x"},
               %{"title" => "y", "summary" => "y", "score" => 6.0, "artifact" => "y"}
             ])
         )}
      ])

      assert :ok = perform_job(IterationWorker, %{session_id: session.id})

      [spec] = FakeRunner.executed_specs()
      home = Application.fetch_env!(:harness, :harness_home)
      expected_path = Path.join([home, "repos", String.replace(repo, "/", "--")])
      assert spec.prompt =~ expected_path, "prompt must contain checkout path for bare-name match"
    end

    test "non-policy repo mention attaches nothing and journals the skip" do
      {session, _root} =
        Ideation.start_session(%{
          seed_prompt: "look at notinpolicy/somerepo for ideas",
          budget_minutes: 180
        })

      journal = Ideation.read_journal(session)
      assert journal =~ "not in policy", "journal must record the skip"
      assert journal =~ "notinpolicy/somerepo", "journal must name the skipped ref"

      # No grounding repos attached
      assert Ideation.grounding_repos(session) == []
    end

    test "critique prompt also includes the checkout path when seed references a policy repo",
         %{repo: repo} do
      {session, root} =
        Ideation.start_session(%{
          seed_prompt: "rethink everything in #{repo}",
          budget_minutes: 180
        })

      Ideation.add_child!(session, root, %{title: "idea", score: 7.0}, "artifact")
      Ideation.update_session!(session, %{iterations: 5})
      Harness.Repo.delete_all(Oban.Job)

      FakeRunner.script([
        {:ok,
         Harness.Fixtures.runner_result(
           structured_output: %{
             "rescored" => [],
             "drift" => false,
             "material_progress" => true,
             "note" => "good progress"
           }
         )}
      ])

      assert :ok = perform_job(CritiqueWorker, %{session_id: session.id})

      [spec] = FakeRunner.executed_specs()
      home = Application.fetch_env!(:harness, :harness_home)
      expected_path = Path.join([home, "repos", String.replace(repo, "/", "--")])
      assert spec.prompt =~ expected_path, "critique prompt must contain checkout path"
    end
  end
end
