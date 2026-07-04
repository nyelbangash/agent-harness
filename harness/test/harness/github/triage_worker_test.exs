defmodule Harness.GitHub.TriageWorkerTest do
  use Harness.DataCase, async: false

  alias Harness.GitHub
  alias Harness.GitHub.{PlanWorker, TriageWorker}
  alias Harness.Runs.FakeRunner

  @moduletag :capture_log

  setup do
    # comments fetch: not stubbed per-test → return an error → worker tolerates
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

    # local git remote so Repos.ensure_base!/repo_map work offline
    tmp = Path.join(System.tmp_dir!(), "triage-worker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo_name = "owner/tw#{System.unique_integer([:positive])}"
    create_git_remote!(tmp, repo_name)
    Application.put_env(:harness, :github_remote_base, "file://#{tmp}/")

    on_exit(fn ->
      Application.delete_env(:harness, :github_req_options)
      Application.delete_env(:harness, :github_remote_base)
      File.rm_rf!(tmp)
    end)

    %{repo: repo_name}
  end

  defp perform(issue) do
    perform_job(TriageWorker, %{issue_id: issue.id})
  end

  test "happy path: proposed plan → triaged, PlanWorker enqueued, audit row written", %{repo: repo} do
    issue = issue_fixture(%{repo: repo})

    FakeRunner.script([
      {:ok, runner_result(structured_output: triage_output(%{route: "plan", confidence: 0.85}))}
    ])

    assert :ok = perform(issue)

    issue = GitHub.get_issue!(issue.id)
    assert issue.pipeline_state == "triaged"
    assert_enqueued(worker: PlanWorker, args: %{issue_id: issue.id})

    triage = GitHub.latest_triage(issue.id)
    assert triage.proposed_route == "plan"
    assert triage.final_route == "plan"
    assert triage.decision_reason == "proposed_plan"
    assert triage.confidence == 0.85
    assert triage.model == "sonnet"
    assert triage.attempt == 1
    assert triage.run_id

    # the run got a repo-grounded prompt with the security framing
    [spec] = FakeRunner.executed_specs()
    assert spec.kind == :triage
    assert spec.output_mode == :json
    assert spec.json_schema =~ "additionalProperties"
    assert spec.prompt =~ "untrusted"
    assert spec.prompt =~ issue.title
    assert spec.prompt =~ "Repository map"
    assert spec.max_turns == 12
  end

  test "model auto proposal is demoted by policy in plan_only mode", %{repo: repo} do
    issue = issue_fixture(%{repo: repo})

    FakeRunner.script([
      {:ok,
       runner_result(
         structured_output:
           triage_output(%{route: "auto", confidence: 0.95, estimated_scope: "xs"})
       )}
    ])

    assert :ok = perform(issue)

    triage = GitHub.latest_triage(issue.id)
    assert triage.proposed_route == "auto"
    assert triage.final_route == "plan"
    assert triage.decision_reason in ["mode_not_full_auto", "no_test_command"]
    assert_enqueued(worker: PlanWorker)
  end

  test "contract violation retries once in-attempt, then succeeds", %{repo: repo} do
    issue = issue_fixture(%{repo: repo})

    FakeRunner.script([
      {:ok, runner_result(structured_output: %{"route" => "invalid route"})},
      fn spec ->
        assert spec.prompt =~ "violated the output contract"
        {:ok, runner_result(structured_output: triage_output())}
      end
    ])

    assert :ok = perform(issue)

    triage = GitHub.latest_triage(issue.id)
    assert triage.attempt == 2
    assert triage.final_route == "plan"
    assert length(FakeRunner.executed_specs()) == 2
  end

  test "two contract violations → contract_failure, still routed to plan", %{repo: repo} do
    issue = issue_fixture(%{repo: repo})

    FakeRunner.script([
      {:ok, runner_result(structured_output: %{"bogus" => true})},
      {:ok, runner_result(structured_output: %{"still" => "bogus"})}
    ])

    assert :ok = perform(issue)

    triage = GitHub.latest_triage(issue.id)
    assert triage.proposed_route == nil
    assert triage.final_route == "plan"
    assert triage.decision_reason == "contract_failure"
    assert_enqueued(worker: PlanWorker, args: %{issue_id: issue.id})
  end

  test "low confidence escalates once to the opus escalation model", %{repo: repo} do
    issue = issue_fixture(%{repo: repo})

    FakeRunner.script([
      {:ok, runner_result(structured_output: triage_output(%{confidence: 0.3, route: "plan"}))},
      fn spec ->
        assert spec.model == "opus"
        {:ok, runner_result(structured_output: triage_output(%{confidence: 0.9, route: "plan"}))}
      end
    ])

    assert :ok = perform(issue)

    triage = GitHub.latest_triage(issue.id)
    assert triage.model == "opus"
    assert triage.confidence == 0.9
    assert length(FakeRunner.executed_specs()) == 2
  end

  test "human-only label short-circuits with zero model spend", %{repo: repo} do
    issue = issue_fixture(%{repo: repo, labels: ["human-only"]})
    FakeRunner.script([])

    assert :ok = perform(issue)

    assert GitHub.get_issue!(issue.id).pipeline_state == "skipped"
    assert FakeRunner.executed_specs() == []
    refute_enqueued(worker: PlanWorker)
  end

  test "paused mode snoozes without any runner call", %{repo: repo} do
    issue = issue_fixture(%{repo: repo})
    FakeRunner.script([])

    original = Application.fetch_env!(:harness, :policy_path)
    tmp = Path.join(System.tmp_dir!(), "paused-#{System.unique_integer([:positive])}.yaml")
    File.write!(tmp, File.read!(original) |> String.replace("mode: plan_only", "mode: paused"))
    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
    end)

    assert {:snooze, _} = perform(issue)
    assert FakeRunner.executed_specs() == []
  end

  test "runner infrastructure errors bubble for Oban retry", %{repo: repo} do
    issue = issue_fixture(%{repo: repo})
    FakeRunner.script([{:error, {:cli_exit, 1}}])

    assert {:error, {:cli_exit, 1}} = perform(issue)
    # issue is parked back in incoming so the retry re-enters cleanly
    assert GitHub.get_issue!(issue.id).pipeline_state == "incoming"
  end
end
