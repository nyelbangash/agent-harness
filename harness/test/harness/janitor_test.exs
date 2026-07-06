defmodule Harness.JanitorTest do
  use Harness.DataCase, async: false

  import ExUnit.CaptureLog

  alias Harness.{GitHub, Janitor, Runs}
  alias Harness.GitHub.TriageWorker

  @moduletag :capture_log

  test "reaps runs stuck at running with no live server" do
    run = Runs.create_run!(%{kind: "plan", status: "queued", model: "sonnet"})
    Runs.update_run!(run, %{status: "running", started_at: DateTime.utc_now()})

    assert :ok = perform_job(Janitor, %{})

    run = Runs.get_run!(run.id)
    assert run.status == "failed"
    assert run.error =~ "reaped"
    assert run.ended_at
  end

  test "leaves runs with a live registered server alone" do
    run = Runs.create_run!(%{kind: "plan", status: "queued", model: "sonnet"})
    Runs.update_run!(run, %{status: "running"})

    # simulate a live RunServer holding the registry key
    test = self()

    holder =
      spawn_link(fn ->
        Registry.register(Harness.Runs.Registry, run.id, nil)
        send(test, :registered)

        receive do
          :done -> :ok
        end
      end)

    assert_receive :registered

    assert :ok = perform_job(Janitor, %{})
    assert Runs.get_run!(run.id).status == "running"

    send(holder, :done)
  end

  test "unwedges issues stuck in triaging with no job and no run" do
    issue = issue_fixture(%{pipeline_state: "triaging"})

    assert :ok = perform_job(Janitor, %{})

    assert GitHub.get_issue!(issue.id).pipeline_state == "incoming"
    assert_enqueued(worker: TriageWorker, args: %{issue_id: issue.id})
  end

  test "does not unwedge an issue that still has an incomplete job" do
    issue = issue_fixture(%{pipeline_state: "triaging"})
    %{issue_id: issue.id} |> TriageWorker.new() |> Oban.insert()

    assert :ok = perform_job(Janitor, %{})
    assert GitHub.get_issue!(issue.id).pipeline_state == "triaging"
  end

  test "re-enqueues triage when GitHub updated an issue after its last triage" do
    issue = issue_fixture(%{pipeline_state: "triaged"})

    GitHub.record_triage!(%{
      issue_id: issue.id,
      proposed_route: "plan",
      final_route: "plan",
      decision_reason: "proposed_plan"
    })

    # GitHub update lands after the triage row
    issue
    |> Harness.GitHub.Issue.changeset(%{
      github_updated_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
    |> Repo.update!()

    assert :ok = perform_job(Janitor, %{})
    assert_enqueued(worker: TriageWorker, args: %{issue_id: issue.id})
  end

  test "settled issues with up-to-date triage are left alone" do
    issue =
      issue_fixture(%{
        pipeline_state: "triaged",
        github_updated_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

    GitHub.record_triage!(%{
      issue_id: issue.id,
      proposed_route: "plan",
      final_route: "plan",
      decision_reason: "proposed_plan"
    })

    assert :ok = perform_job(Janitor, %{})
    refute_enqueued(worker: TriageWorker)
  end

  test "starts a configured queue absent from running Oban" do
    current = Application.fetch_env!(:harness, Oban)
    updated = Keyword.update!(current, :queues, &Keyword.put(&1, :ghost, 1))
    Application.put_env(:harness, Oban, updated)

    on_exit(fn ->
      Application.put_env(:harness, Oban, current)
    end)

    log = capture_log(fn -> assert :ok = perform_job(Janitor, %{}) end)
    assert log =~ "starting queue ghost"
  end

  test "no-op when all configured queues are already running" do
    assert :ok = perform_job(Janitor, %{})
  end
end
