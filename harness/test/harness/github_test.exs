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

  describe "harness_caused_update?/1" do
    setup do
      Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
      on_exit(fn -> Application.delete_env(:harness, :github_req_options) end)
      :ok
    end

    defp stub_newest_comment(comment) do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, List.wrap(comment)) end)
    end

    test "never self-acked (last_self_ack_comment_id nil) is not harness-caused" do
      issue = issue_fixture(%{last_self_ack_comment_id: nil})

      stub_newest_comment(%{
        "id" => 1,
        "body" => Harness.GitHub.Provenance.stamp("hi", "plan", "run-1"),
        "created_at" => "2026-07-04T13:00:00Z"
      })

      refute GitHub.harness_caused_update?(issue)
    end

    test "self-ack id matches the newest stamped comment's id" do
      issue = issue_fixture(%{last_self_ack_comment_id: 42})

      stub_newest_comment(%{
        "id" => 42,
        "body" => Harness.GitHub.Provenance.stamp("hi", "plan", "run-1"),
        "created_at" => "2026-07-04T13:00:00Z"
      })

      assert GitHub.harness_caused_update?(issue)
    end

    test "self-ack id matches but the comment body carries no provenance marker" do
      issue = issue_fixture(%{last_self_ack_comment_id: 42})

      stub_newest_comment(%{
        "id" => 42,
        "body" => "not stamped",
        "created_at" => "2026-07-04T13:00:00Z"
      })

      refute GitHub.harness_caused_update?(issue)
    end
  end
end
