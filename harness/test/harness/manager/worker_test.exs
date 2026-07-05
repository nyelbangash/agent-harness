defmodule Harness.Manager.WorkerTest do
  use Harness.DataCase, async: false

  alias Harness.{GitHub, Runs}
  alias Harness.GitHub.TriageWorker
  alias Harness.Manager.{LampServer, Worker}

  @moduletag :capture_log

  @pt_policy_key {Harness.Policy.Server, :policy}

  setup do
    # Clear all lamps.
    for lamp <-
          ~w(loop_signature wedged_lane stalled_run stranded_state artifact_drift telemetry_silence stale_code)a do
      LampServer.clear(lamp)
    end

    # Route notifications to this process.
    Harness.Notify.TestBackend.subscribe()
    Application.put_env(:harness, :notify_backend, Harness.Notify.TestBackend)

    # Save policy so we can restore it after the test.
    prev_policy = :persistent_term.get(@pt_policy_key, :missing)

    on_exit(fn ->
      Application.put_env(:harness, :notify_backend, Harness.Notify.TestBackend)

      if prev_policy == :missing,
        do: :persistent_term.erase(@pt_policy_key),
        else: :persistent_term.put(@pt_policy_key, prev_policy)
    end)

    :ok
  end

  # Set a test policy with manager configuration. poll_minutes: 0 bypasses
  # the self-throttle so every test call runs the full sweep.
  defp set_policy(authority) do
    base = :persistent_term.get(@pt_policy_key, Harness.Policy.get())

    manager = %Harness.Policy.Schema.Manager{
      enabled: true,
      poll_minutes: 0,
      authority: authority,
      loop_triage_threshold: 5,
      loop_window_minutes: 30,
      stall_minutes: 1,
      ghost_job_grace_seconds: 60,
      telemetry_silence_samples: 3
    }

    :persistent_term.put(@pt_policy_key, %{base | manager: manager})
  end

  defp set_disabled_policy do
    base = :persistent_term.get(@pt_policy_key, Harness.Policy.get())

    :persistent_term.put(@pt_policy_key, %{
      base
      | manager: %Harness.Policy.Schema.Manager{enabled: false}
    })
  end

  defp find_lamp(class), do: Enum.find(LampServer.get_all(), &(&1.class == class))

  # -- Detection: loop signature -----------------------------------------------

  test "detects loop signature and sets lamp (does not modify pipeline_state)" do
    set_policy("tier0")
    issue = issue_fixture(%{pipeline_state: "triaged"})

    for _ <- 1..6 do
      Runs.create_run!(%{
        kind: "triage",
        status: "succeeded",
        issue_id: issue.id,
        model: "sonnet"
      })
    end

    assert :ok = perform_job(Worker, %{})

    assert find_lamp(:loop_signature).status == :on
    assert GitHub.get_issue!(issue.id).pipeline_state == "triaged"
  end

  # -- Detection: stranded state -----------------------------------------------

  test "detects implementing issue with no job and no run, normalizes to incoming" do
    set_policy("tier0")
    issue = issue_fixture(%{pipeline_state: "implementing"})

    assert :ok = perform_job(Worker, %{})

    assert find_lamp(:stranded_state).status == :on
    assert GitHub.get_issue!(issue.id).pipeline_state == "incoming"
    assert_enqueued(worker: TriageWorker, args: %{issue_id: issue.id})
  end

  test "does not touch implementing issue that has a live RunServer" do
    set_policy("tier0")
    issue = issue_fixture(%{pipeline_state: "implementing"})

    run =
      Runs.create_run!(%{
        kind: "implement",
        status: "running",
        issue_id: issue.id,
        model: "sonnet"
      })

    test_pid = self()

    holder =
      spawn_link(fn ->
        Registry.register(Harness.Runs.Registry, run.id, nil)
        send(test_pid, :registered)

        receive do
          :done -> :ok
        end
      end)

    assert_receive :registered

    assert :ok = perform_job(Worker, %{})

    assert GitHub.get_issue!(issue.id).pipeline_state == "implementing"
    refute_enqueued(worker: TriageWorker)

    send(holder, :done)
  end

  # -- Detection: stalled run --------------------------------------------------

  test "detects stalled run (live Registry, no recent events) and sets lamp but does not kill" do
    set_policy("tier1")
    issue = issue_fixture()

    run =
      Runs.create_run!(%{
        kind: "implement",
        status: "running",
        issue_id: issue.id,
        model: "sonnet"
      })

    old_start = DateTime.add(DateTime.utc_now(), -3600, :second)
    Runs.update_run!(run, %{started_at: old_start})
    run = Runs.get_run!(run.id)

    test_pid = self()

    holder =
      spawn_link(fn ->
        Registry.register(Harness.Runs.Registry, run.id, nil)
        send(test_pid, :registered)

        receive do
          :done -> :ok
        end
      end)

    assert_receive :registered

    assert :ok = perform_job(Worker, %{})

    assert find_lamp(:stalled_run).status == :on
    assert Runs.get_run!(run.id).status == "running"

    send(holder, :done)
  end

  # -- Detection: artifact drift -----------------------------------------------

  test "detects incoming issue with a ready plan and advances to plan_ready" do
    set_policy("tier0")
    issue = issue_fixture(%{pipeline_state: "incoming"})

    run =
      Runs.create_run!(%{kind: "plan", status: "succeeded", issue_id: issue.id, model: "sonnet"})

    GitHub.record_plan!(%{
      issue_id: issue.id,
      run_id: run.id,
      plan_path: "/tmp/PLAN.md",
      context_path: "/tmp/CONTEXT.md"
    })

    assert :ok = perform_job(Worker, %{})

    assert find_lamp(:artifact_drift).status == :on
    assert GitHub.get_issue!(issue.id).pipeline_state == "plan_ready"
  end

  # -- Ghost job: live RunServer protects the job ------------------------------

  test "ghost job check: job for issue with live RunServer is not cancelled" do
    set_policy("tier0")
    issue = issue_fixture(%{pipeline_state: "implementing"})

    run =
      Runs.create_run!(%{
        kind: "implement",
        status: "running",
        issue_id: issue.id,
        model: "sonnet"
      })

    job = %{issue_id: issue.id} |> Harness.GitHub.ImplementWorker.new() |> Oban.insert!()
    old_time = DateTime.add(DateTime.utc_now(), -600, :second)

    Repo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "executing", attempted_at: old_time]
    )

    test_pid = self()

    holder =
      spawn_link(fn ->
        Registry.register(Harness.Runs.Registry, run.id, nil)
        send(test_pid, :registered)

        receive do
          :done -> :ok
        end
      end)

    assert_receive :registered

    assert :ok = perform_job(Worker, %{})

    oban_job = Repo.get!(Oban.Job, job.id)
    assert oban_job.state == "executing"

    send(holder, :done)
  end

  # -- Tier-1 proposals --------------------------------------------------------

  test "loop signature sends tier-1 notification but modifies nothing when authority=tier1" do
    set_policy("tier1")
    issue = issue_fixture(%{pipeline_state: "triaged"})

    for _ <- 1..6 do
      Runs.create_run!(%{
        kind: "triage",
        status: "succeeded",
        issue_id: issue.id,
        model: "sonnet"
      })
    end

    assert :ok = perform_job(Worker, %{})

    assert_receive {:notify, :manager_proposal, _, _}
    assert GitHub.get_issue!(issue.id).pipeline_state == "triaged"
    refute_enqueued(worker: TriageWorker, args: %{issue_id: issue.id})
  end

  test "loop signature does NOT send notification when authority=tier0" do
    set_policy("tier0")
    issue = issue_fixture(%{pipeline_state: "triaged"})

    for _ <- 1..6 do
      Runs.create_run!(%{
        kind: "triage",
        status: "succeeded",
        issue_id: issue.id,
        model: "sonnet"
      })
    end

    assert :ok = perform_job(Worker, %{})

    refute_receive {:notify, :manager_proposal, _, _}, 100
  end

  # -- Policy: disabled manager ------------------------------------------------

  test "disabled manager does nothing — no lamps, no repairs, no notifications" do
    set_disabled_policy()
    issue = issue_fixture(%{pipeline_state: "implementing"})

    assert :ok = perform_job(Worker, %{})

    assert Enum.all?(LampServer.get_all(), &(&1.status == :off))
    assert GitHub.get_issue!(issue.id).pipeline_state == "implementing"
    refute_receive {:notify, _, _, _}, 100
  end

  # -- Lamp cleared when no anomaly --------------------------------------------

  test "lamp is cleared on next sweep when anomaly is gone" do
    set_policy("tier0")
    LampServer.set(:stranded_state, "manual")

    # No stranded issues in DB → lamp clears
    assert :ok = perform_job(Worker, %{})

    assert find_lamp(:stranded_state).status == :off
  end
end
