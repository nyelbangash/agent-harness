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

  test "does NOT re-triage when the delta is the harness own stamped comment (the #75 loop)" do
    issue = issue_fixture(%{pipeline_state: "plan_ready"})

    GitHub.record_triage!(%{
      issue_id: issue.id,
      proposed_route: "plan",
      final_route: "plan",
      decision_reason: "proposed_plan"
    })

    # the #28 self-ack advanced github_updated_at past the triage row because
    # WE posted the plan comment; the newest comment is harness-stamped
    comment_time = DateTime.add(DateTime.utc_now(), 3600, :second)

    issue
    |> Harness.GitHub.Issue.changeset(%{github_updated_at: comment_time})
    |> Repo.update!()

    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:harness, :github_req_options) end)

    stamped = Harness.GitHub.Provenance.stamp("## Implementation plan", "plan", 1)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, [
        %{
          "body" => stamped,
          "created_at" => DateTime.to_iso8601(comment_time)
        }
      ])
    end)

    assert :ok = perform_job(Janitor, %{})
    refute_enqueued(worker: TriageWorker, args: %{issue_id: issue.id})
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

  describe "auto-clear stale terminal issues" do
    defp backdate_terminal!(issue, seconds_ago) do
      from(i in Harness.GitHub.Issue, where: i.id == ^issue.id)
      |> Repo.update_all(
        set: [terminal_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)]
      )

      GitHub.get_issue!(issue.id)
    end

    test "dismisses a terminal issue older than the configured threshold" do
      issue = issue_fixture(%{pipeline_state: "failed"}) |> backdate_terminal!(15 * 86_400)

      assert :ok = perform_job(Janitor, %{})

      assert GitHub.get_issue!(issue.id).dismissed_at
    end

    test "leaves a terminal issue within the threshold alone" do
      issue = issue_fixture(%{pipeline_state: "done"}) |> backdate_terminal!(1 * 86_400)

      assert :ok = perform_job(Janitor, %{})

      refute GitHub.get_issue!(issue.id).dismissed_at
    end

    test "never touches a non-terminal issue regardless of age" do
      issue = issue_fixture(%{pipeline_state: "triaged"}) |> backdate_terminal!(30 * 86_400)

      assert :ok = perform_job(Janitor, %{})

      refute GitHub.get_issue!(issue.id).dismissed_at
    end

    test "ages by terminal_at, not by updated_at churn from routine polling" do
      issue = issue_fixture(%{pipeline_state: "failed"}) |> backdate_terminal!(15 * 86_400)

      # PollWorker polls every ~2 minutes; even when nothing about the issue
      # changed, upsert_issue's :unchanged branch still touches the record
      # (Ecto bumps `updated_at` on every Repo.update!, changed or not).
      # That must not reset the auto-clear clock (issue #76 regression).
      assert {:unchanged, _} =
               GitHub.upsert_issue(issue.repo, gh_issue_payload(%{"number" => issue.number}))

      assert :ok = perform_job(Janitor, %{})

      assert GitHub.get_issue!(issue.id).dismissed_at
    end

    test "leaves a terminal issue with no terminal_at stamped alone" do
      issue = issue_fixture(%{pipeline_state: "failed"})

      assert :ok = perform_job(Janitor, %{})

      refute GitHub.get_issue!(issue.id).dismissed_at
    end

    test "stamps terminal_at when an issue transitions into a terminal state" do
      issue = issue_fixture(%{pipeline_state: "triaged"})

      refute issue.terminal_at

      failed = GitHub.transition!(issue, "failed")

      assert failed.terminal_at
    end

    test "clears terminal_at when an issue leaves a terminal state" do
      issue = issue_fixture(%{pipeline_state: "failed"})
      failed = GitHub.transition!(issue, "failed")
      assert failed.terminal_at

      retriaged = GitHub.transition!(failed, "incoming")

      refute retriaged.terminal_at
    end
  end
end
