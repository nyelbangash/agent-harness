defmodule Harness.Briefing.WorkerTest do
  use Harness.DataCase, async: false

  alias Harness.{Briefing, GitHub, Repo, Runs}
  alias Harness.Briefing.Worker

  @moduletag :capture_log

  setup do
    Harness.Notify.TestBackend.subscribe()
    :ok
  end

  test "assembles a briefing with data for each section" do
    issue =
      issue_fixture(%{
        pipeline_state: "pr_open",
        pr_url: "https://github.com/o/r/pull/1",
        title: "Fix the thing"
      })

    GitHub.record_triage!(%{
      issue_id: issue.id,
      final_route: "plan",
      decision_reason: "multi-file change"
    })

    run = Runs.create_run!(%{kind: "plan", status: "failed", ref: "o/r##{issue.number}"})
    Runs.update_run!(run, %{error: "Plan generation failed"})

    assert :ok = perform_job(Worker, %{})

    briefing = Repo.one!(Briefing)
    assert briefing.date == Date.utc_today()
    assert briefing.markdown =~ "Fix the thing"
    assert briefing.markdown =~ "plan"
  end

  test "empty-overnight renders quiet night" do
    assert :ok = perform_job(Worker, %{})

    briefing = Repo.one!(Briefing)
    assert briefing.date == Date.utc_today()
    assert briefing.markdown =~ "Quiet night"
  end

  test "empty-overnight sends quiet night one-liner via notify" do
    assert :ok = perform_job(Worker, %{})

    assert_receive {:notify, :briefing, "Harness · Morning briefing", "Quiet night"}
  end

  test "idempotency: two runs on the same date produce one row" do
    assert :ok = perform_job(Worker, %{})
    assert :ok = perform_job(Worker, %{})

    assert Repo.aggregate(Briefing, :count, :id) == 1
  end

  test "one-liner counts non-zero sections" do
    issue =
      issue_fixture(%{
        pipeline_state: "pr_open",
        pr_url: "https://github.com/o/r/pull/1",
        title: "Open PR"
      })

    _issue2 =
      issue_fixture(%{
        pipeline_state: "pr_open",
        pr_url: "https://github.com/o/r/pull/2",
        title: "Another PR"
      })

    run = Runs.create_run!(%{kind: "triage", status: "failed", issue_id: issue.id, ref: "o/r#1"})
    Runs.update_run!(run, %{error: "oops"})

    assert :ok = perform_job(Worker, %{})

    assert_receive {:notify, :briefing, "Harness · Morning briefing", one_liner}
    assert one_liner =~ "PR"
    assert one_liner =~ "failure"
    assert one_liner =~ "·"
  end

  test "triage counts appear in briefing" do
    issue = issue_fixture(%{pipeline_state: "triaged"})

    GitHub.record_triage!(%{issue_id: issue.id, final_route: "auto", decision_reason: "xs"})
    GitHub.record_triage!(%{issue_id: issue.id, final_route: "plan", decision_reason: "large"})

    assert :ok = perform_job(Worker, %{})

    briefing = Repo.one!(Briefing)
    assert briefing.markdown =~ "auto"
    assert briefing.markdown =~ "plan"
  end

  test "failures section lists failed and killed runs" do
    run =
      Runs.create_run!(%{kind: "implement", status: "failed", ref: "org/repo#99"})

    Runs.update_run!(run, %{error: "Process exited with code 1"})

    assert :ok = perform_job(Worker, %{})

    briefing = Repo.one!(Briefing)
    assert briefing.markdown =~ "implement"
    assert briefing.markdown =~ "org/repo#99"
  end

  test "budget section always appears when not quiet night" do
    issue_fixture(%{
      pipeline_state: "pr_open",
      pr_url: "https://github.com/o/r/pull/1",
      title: "Budget test PR"
    })

    assert :ok = perform_job(Worker, %{})

    briefing = Repo.one!(Briefing)
    assert briefing.markdown =~ "Budget Position"
    assert briefing.markdown =~ "Opus hours"
    assert briefing.markdown =~ "Overflow"
  end
end
