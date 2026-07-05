defmodule Harness.GitHub.PlanWorkerTest do
  use Harness.DataCase, async: false

  alias Harness.GitHub
  alias Harness.GitHub.PlanWorker
  alias Harness.Runs.FakeRunner

  @moduletag :capture_log

  @plan_md String.duplicate("# Plan\n\nA thorough, file-specific plan body.\n", 20)
  @context_md String.duplicate("# Context\n\nsrc/widget.ex:1-20 — the widget.\n", 20)

  setup do
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

    tmp = Path.join(System.tmp_dir!(), "plan-worker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo_name = "owner/pw#{System.unique_integer([:positive])}"
    create_git_remote!(tmp, repo_name)
    Application.put_env(:harness, :github_remote_base, "file://#{tmp}/")

    on_exit(fn ->
      Application.delete_env(:harness, :github_req_options)
      Application.delete_env(:harness, :github_remote_base)
      File.rm_rf!(tmp)
    end)

    %{repo: repo_name, remote_base: tmp}
  end

  defp writes_artifacts do
    fn spec ->
      File.write!(Path.join(spec.cwd, "PLAN.md"), @plan_md)
      File.write!(Path.join(spec.cwd, "CONTEXT.md"), @context_md)
      {:ok, Harness.Fixtures.runner_result()}
    end
  end

  test "happy path: artifacts persisted, branch pushed by the host, plan_ready", ctx do
    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "triaged"})
    FakeRunner.script([writes_artifacts()])

    assert :ok = perform_job(PlanWorker, %{issue_id: issue.id})

    issue = GitHub.get_issue!(issue.id)
    assert issue.pipeline_state == "plan_ready"

    # artifacts survive worktree cleanup
    plan = GitHub.ready_plan(issue.id)
    assert File.read!(plan.plan_path) == @plan_md
    assert File.read!(plan.context_path) == @context_md
    assert plan.summary =~ "thorough"
    assert plan.branch == "harness/plans/issue-#{issue.number}"
    assert plan.issue_comment_id == nil

    # the branch actually landed on the (local fixture) remote
    bare = Path.join(ctx.remote_base, ctx.repo <> ".git")
    {refs, 0} = System.cmd("git", ["ls-remote", "file://#{bare}", "refs/heads/harness/plans/*"])
    assert refs =~ "harness/plans/issue-#{issue.number}"

    # worktree cleaned up
    assert {:ok, []} = File.ls(Application.fetch_env!(:harness, :workspaces_dir))

    # the agent run was stream-json in a worktree with Write allowed
    [spec] = FakeRunner.executed_specs()
    assert spec.kind == :plan
    assert spec.output_mode == :stream_json
    assert "Write" in spec.allowed_tools
    assert spec.max_turns == 40
    assert spec.prompt =~ "PLAN.md"
    assert spec.prompt =~ "untrusted"
  end

  test "post_to_issue policy publishes a comment instead of a branch", ctx do
    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "triaged"})
    FakeRunner.script([writes_artifacts()])

    captured = start_supervised!({Agent, fn -> nil end})

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path =~ "/comments"} do
        {"GET", true} ->
          Req.Test.json(conn, [])

        {"POST", true} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          Agent.update(captured, fn _ -> Jason.decode!(raw)["body"] end)
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 4242, "created_at" => "2026-07-05T10:00:00Z"})

        {"GET", false} ->
          # the self-acknowledge fetch after posting (issue #28)
          Req.Test.json(conn, %{"updated_at" => "2030-01-01T00:00:00Z"})

        _ ->
          Plug.Conn.send_resp(conn, 500, "")
      end
    end)

    original = Application.fetch_env!(:harness, :policy_path)
    tmp = Path.join(System.tmp_dir!(), "post-to-issue-#{System.unique_integer([:positive])}.yaml")

    File.write!(
      tmp,
      File.read!(original) |> String.replace("post_to_issue: false", "post_to_issue: true")
    )

    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
    end)

    assert :ok = perform_job(PlanWorker, %{issue_id: issue.id})

    plan = GitHub.ready_plan(issue.id)
    assert plan.issue_comment_id == 4242
    assert plan.branch == nil

    body = Agent.get(captured, & &1)
    assert Harness.GitHub.Provenance.harness_authored?(body)

    # self-acknowledge: the stored updated_at swallowed our own comment bump,
    # so the next poll will not re-triage this issue (the #4 feedback loop)
    assert GitHub.get_issue!(issue.id).github_updated_at ==
             ~U[2030-01-01 00:00:00.000000Z]
  end

  test "a run that writes no artifacts fails the issue", ctx do
    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "triaged"})
    FakeRunner.script([{:ok, Harness.Fixtures.runner_result()}])

    assert {:error, :missing_plan_artifacts} = perform_job(PlanWorker, %{issue_id: issue.id})
    assert GitHub.get_issue!(issue.id).pipeline_state == "failed"
    assert GitHub.ready_plan(issue.id) == nil
    assert {:ok, []} = File.ls(Application.fetch_env!(:harness, :workspaces_dir))
  end

  test "trivially small artifacts are rejected too", ctx do
    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "triaged"})

    FakeRunner.script([
      fn spec ->
        File.write!(Path.join(spec.cwd, "PLAN.md"), "todo")
        File.write!(Path.join(spec.cwd, "CONTEXT.md"), "stuff")
        {:ok, Harness.Fixtures.runner_result()}
      end
    ])

    assert {:error, :missing_plan_artifacts} = perform_job(PlanWorker, %{issue_id: issue.id})
    assert GitHub.get_issue!(issue.id).pipeline_state == "failed"
  end

  test "a killed run cancels the job and fails the issue", ctx do
    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "triaged"})
    FakeRunner.script([{:error, :killed}])

    assert {:cancel, :killed} = perform_job(PlanWorker, %{issue_id: issue.id})
    assert GitHub.get_issue!(issue.id).pipeline_state == "failed"
    assert {:ok, []} = File.ls(Application.fetch_env!(:harness, :workspaces_dir))
  end

  test "re-planning supersedes the earlier packet", ctx do
    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "triaged"})

    FakeRunner.script([writes_artifacts()])
    assert :ok = perform_job(PlanWorker, %{issue_id: issue.id})
    first = GitHub.ready_plan(issue.id)

    FakeRunner.script([writes_artifacts()])
    assert :ok = perform_job(PlanWorker, %{issue_id: issue.id})
    second = GitHub.ready_plan(issue.id)

    assert second.id != first.id
    assert Harness.Repo.get!(Harness.GitHub.Plan, first.id).status == "superseded"
  end
end
