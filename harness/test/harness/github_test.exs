defmodule Harness.GitHubTest do
  use Harness.DataCase, async: false

  alias Harness.GitHub

  @moduletag :capture_log

  describe "dismiss_issue!/1" do
    test "sets dismissed_at and broadcasts, without touching the row otherwise" do
      GitHub.subscribe()
      issue = issue_fixture(%{pipeline_state: "failed"})

      dismissed = GitHub.dismiss_issue!(issue)

      assert dismissed.dismissed_at
      assert dismissed.pipeline_state == "failed"
      assert_receive {:issue_updated, %{id: id}} when id == issue.id
    end

    test "board/0 excludes a dismissed issue" do
      issue = issue_fixture(%{pipeline_state: "failed", title: "Dismiss me"})
      GitHub.dismiss_issue!(issue)

      board = GitHub.board()
      all_issues = board |> Map.values() |> List.flatten()
      refute Enum.any?(all_issues, &(&1.id == issue.id))

      # the row itself is untouched — the poller still finds it as "known"
      assert GitHub.get_issue_by(issue.repo, issue.number)
    end
  end

  describe "dismiss_issues!/1" do
    test "bulk-dismisses every id and broadcasts for each" do
      GitHub.subscribe()
      a = issue_fixture(%{pipeline_state: "done"})
      b = issue_fixture(%{pipeline_state: "skipped"})

      [updated_a, updated_b] = GitHub.dismiss_issues!([a.id, b.id]) |> Enum.sort_by(& &1.id)
      [a, b] = Enum.sort_by([a, b], & &1.id)

      assert updated_a.id == a.id and updated_a.dismissed_at
      assert updated_b.id == b.id and updated_b.dismissed_at

      assert_receive {:issue_updated, %{id: id1}} when id1 in [a.id, b.id]
      assert_receive {:issue_updated, %{id: id2}} when id2 in [a.id, b.id]
    end
  end

  describe "transition!/2" do
    test "re-entering the pipeline clears a prior dismissal" do
      issue = issue_fixture(%{pipeline_state: "failed"})
      dismissed = GitHub.dismiss_issue!(issue)
      assert dismissed.dismissed_at

      reentered = GitHub.transition!(dismissed, "incoming")
      assert reentered.dismissed_at == nil
      assert reentered.pipeline_state == "incoming"

      all_issues = GitHub.board() |> Map.values() |> List.flatten()
      assert Enum.any?(all_issues, &(&1.id == issue.id))
    end
  end
end
