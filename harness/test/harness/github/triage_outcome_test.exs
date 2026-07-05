defmodule Harness.GitHub.TriageOutcomeTest do
  use Harness.DataCase, async: false

  alias Harness.GitHub
  alias Harness.GitHub.TriageOutcome

  test "valid changeset inserts a row" do
    issue = issue_fixture()
    now = DateTime.utc_now()

    attrs = %{
      issue_id: issue.id,
      outcome: "merged_untouched",
      resolved_at: now,
      days_open: 2.5
    }

    assert {:ok, row} =
             %TriageOutcome{} |> TriageOutcome.changeset(attrs) |> Harness.Repo.insert()

    assert row.outcome == "merged_untouched"
    assert row.shadow == false
    assert row.amend_commit_count == nil
  end

  test "duplicate insert on same issue_id is ignored (on_conflict: :nothing)" do
    issue = issue_fixture()
    now = DateTime.utc_now()
    attrs = %{issue_id: issue.id, outcome: "issue_closed_no_action",
              resolved_at: now, days_open: 1.0}

    GitHub.record_triage_outcome!(attrs)
    GitHub.record_triage_outcome!(attrs)

    assert Harness.Repo.aggregate(TriageOutcome, :count) == 1
  end

  test "invalid outcome string is rejected" do
    issue = issue_fixture()
    attrs = %{issue_id: issue.id, outcome: "not_real", resolved_at: DateTime.utc_now(),
              days_open: 1.0}

    assert {:error, cs} = %TriageOutcome{} |> TriageOutcome.changeset(attrs) |> Harness.Repo.insert()
    assert "is invalid" in errors_on(cs).outcome
  end
end
