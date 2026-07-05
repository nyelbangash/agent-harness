defmodule Harness.Runs.QueueStatsTest do
  use Harness.DataCase, async: false

  alias Harness.Runs

  @limits [triage: 2, implement: 1]

  test "returns configured queues in order with zero counts when idle" do
    assert [triage, implement] = Runs.queue_stats(@limits)

    assert %{queue: "triage", label: "triage", limit: 2, running: 0, waiting: 0} = triage

    assert %{queue: "implement", label: "plan+implement", limit: 1, running: 0, waiting: 0} =
             implement
  end

  test "counts waiting and executing jobs per queue" do
    Oban.insert!(Harness.GitHub.TriageWorker.new(%{issue_id: 1}))
    Oban.insert!(Harness.GitHub.TriageWorker.new(%{issue_id: 2}))
    executing = Oban.insert!(Harness.GitHub.ImplementWorker.new(%{issue_id: 3}))
    Oban.insert!(Harness.GitHub.ImplementWorker.new(%{issue_id: 4}))

    Repo.update_all(
      from(j in "oban_jobs", where: j.id == ^executing.id),
      set: [state: "executing"]
    )

    assert [triage, implement] = Runs.queue_stats(@limits)
    assert %{running: 0, waiting: 2} = triage
    assert %{running: 1, waiting: 1} = implement
  end

  test "defaults to the configured queues (config.exs), implement labeled plan+implement" do
    stats = Runs.queue_stats()
    assert Enum.map(stats, & &1.queue) == ["triage", "implement", "ideate", "ops"]
    assert Enum.find(stats, &(&1.queue == "implement")).label == "plan+implement"
  end

  test "normalizes keyword-style queue limits" do
    assert [%{limit: 3}] = Runs.queue_stats(ops: [limit: 3])
  end
end
