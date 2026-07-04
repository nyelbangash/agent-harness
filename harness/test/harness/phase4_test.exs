defmodule Harness.Phase4Test do
  use Harness.DataCase, async: false

  alias Harness.GitHub.PollWorker
  alias Harness.{GitHub, Runs, Usage}

  @moduletag :capture_log

  describe "overflow hard-pause (§9.5)" do
    test "current_mode forces :pause when overflow spend reaches the cap" do
      # fresh low-utilization sample would otherwise be :full_auto
      Usage.record_oauth_sample!(%{seven_day_utilization: 5.0, raw: %{}})
      assert Usage.current_mode() == :full_auto

      # a run at the $25 weekly cap
      Runs.create_run!(%{kind: "implement", status: "succeeded"})
      |> Runs.update_run!(%{used_overage: true, cost_estimate: 25.0})

      assert Usage.current_mode() == :pause
    end
  end

  describe "run-failed notification" do
    setup do
      Harness.Notify.TestBackend.subscribe()
      # the sandbox recycles issue ids across tests; clear stale dedup keys
      for {k, _} <- :persistent_term.get(),
          match?({Harness.GitHub, :last_failed_notify, _}, k),
          do: :persistent_term.erase(k)

      :ok
    end

    test "an issue entering failed notifies once" do
      issue = issue_fixture(%{pipeline_state: "planning"})
      GitHub.transition!(issue, "failed")
      assert_receive {:notify, :run_failed, _, message}
      assert message =~ "Run failed"

      # re-transitioning within failed does not re-notify
      GitHub.transition!(GitHub.get_issue!(issue.id), "failed")
      refute_receive {:notify, :run_failed, _, _}, 50
    end

    test "an Oban retry re-entering failed does not double-notify (deduped)" do
      # the retry path: planning → failed (attempt 1), then planning → failed
      # again (attempt 2) within the dedupe window
      issue = issue_fixture(%{pipeline_state: "planning"})

      GitHub.transition!(issue, "failed")
      assert_receive {:notify, :run_failed, _, _}

      issue = GitHub.get_issue!(issue.id)
      GitHub.transition!(issue, "planning")
      GitHub.transition!(GitHub.get_issue!(issue.id), "failed")

      refute_receive {:notify, :run_failed, _, _}, 50
    end
  end

  describe "agent-cloud lane deferral" do
    setup do
      Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})

      original = Application.fetch_env!(:harness, :policy_path)

      tmp =
        Path.join(System.tmp_dir!(), "cloud-policy-#{System.unique_integer([:positive])}.yaml")

      File.write!(
        tmp,
        File.read!(original) |> String.replace("repos: []", ~s(repos: ["owner/cloudrepo"]))
      )

      Application.put_env(:harness, :policy_path, tmp)
      Harness.Policy.reload()
      :persistent_term.erase({PollWorker, :login})

      on_exit(fn ->
        Application.delete_env(:harness, :github_req_options)
        Application.put_env(:harness, :policy_path, original)
        Harness.Policy.reload()
        File.rm(tmp)
        :persistent_term.erase({PollWorker, :login})
      end)

      :ok
    end

    test "an agent-cloud issue is deferred, not triaged locally" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/user" ->
            Req.Test.json(conn, %{"login" => "nyelbangash"})

          "/repos/" <> _ ->
            conn
            |> Plug.Conn.put_resp_header("etag", ~s(W/"c1"))
            |> Req.Test.json([
              gh_issue_payload(number: 30, labels: [%{"name" => "agent-cloud"}])
            ])
        end
      end)

      assert :ok = perform_job(PollWorker, %{})

      issue = GitHub.get_issue_by("owner/cloudrepo", 30)
      assert issue.pipeline_state == "skipped"
      refute_enqueued(worker: Harness.GitHub.TriageWorker)
    end

    test "an agent-cloud label added mid-flight cancels the local jobs" do
      # a local triage is already queued for issue 31
      issue =
        issue_fixture(%{
          repo: "owner/cloudrepo",
          number: 31,
          github_id: 31,
          pipeline_state: "planning"
        })

      {:ok, _} = %{issue_id: issue.id} |> Harness.GitHub.PlanWorker.new() |> Oban.insert()
      assert_enqueued(worker: Harness.GitHub.PlanWorker)

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/user" ->
            Req.Test.json(conn, %{"login" => "nyelbangash"})

          "/repos/" <> _ ->
            conn
            |> Plug.Conn.put_resp_header("etag", ~s(W/"c2"))
            |> Req.Test.json([
              gh_issue_payload(number: 31, id: 31, labels: [%{"name" => "agent-cloud"}])
            ])
        end
      end)

      assert :ok = perform_job(PollWorker, %{})

      assert GitHub.get_issue_by("owner/cloudrepo", 31).pipeline_state == "skipped"
      # the queued local job was cancelled
      refute_enqueued(worker: Harness.GitHub.PlanWorker)
    end
  end

  describe "budget warnings (§9.6)" do
    setup do
      Harness.Notify.TestBackend.subscribe()
      :persistent_term.erase({Harness.Usage.PollWorker, :last_budget_warn, :opus})
      :persistent_term.erase({Harness.Usage.PollWorker, :last_budget_warn, :overflow})
      on_exit(fn -> Application.delete_env(:harness, :usage_req_options) end)
      :ok
    end

    test "both caps warn independently when both cross the fraction" do
      now = DateTime.utc_now()

      # 16 opus hours (of 18 cap = 89%) and $22 overflow (of $25 = 88%)
      Runs.create_run!(%{kind: "critique", status: "succeeded", model: "opus"})
      |> Runs.update_run!(%{
        started_at: DateTime.add(now, -16 * 3600, :second),
        ended_at: now
      })

      Runs.create_run!(%{kind: "implement", status: "succeeded"})
      |> Runs.update_run!(%{used_overage: true, cost_estimate: 22.0})

      # the usage endpoint answers with a low utilization so the poll records
      Application.put_env(:harness, :usage_req_options, plug: {Req.Test, __MODULE__})

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"seven_day" => %{"utilization" => 10}})
      end)

      assert :ok = perform_job(Harness.Usage.PollWorker, %{})

      assert_receive {:notify, :budget_warning, _, opus_msg}
      assert_receive {:notify, :budget_warning, _, overflow_msg}
      messages = [opus_msg, overflow_msg]
      assert Enum.any?(messages, &(&1 =~ "Opus hours"))
      assert Enum.any?(messages, &(&1 =~ "Overflow spend"))
    end
  end
end
