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
  end
end
