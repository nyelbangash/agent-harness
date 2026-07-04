defmodule Harness.GitHub.ImplementWorkerTest do
  use Harness.DataCase, async: false

  alias Harness.GitHub
  alias Harness.GitHub.{ImplementWorker, PlanWorker}
  alias Harness.Runs.FakeRunner

  @moduletag :capture_log

  setup do
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

    tmp = Path.join(System.tmp_dir!(), "impl-worker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo_name = "owner/iw#{System.unique_integer([:positive])}"
    bare = create_git_remote!(tmp, repo_name)
    Application.put_env(:harness, :github_remote_base, "file://#{tmp}/")

    on_exit(fn ->
      Application.delete_env(:harness, :github_req_options)
      Application.delete_env(:harness, :github_remote_base)
      File.rm_rf!(tmp)
    end)

    %{repo: repo_name, bare: bare}
  end

  # give the policy a repos entry with commands, without touching other keys
  defp put_repo_policy(repo, test_command, extra \\ "") do
    original = Application.fetch_env!(:harness, :policy_path)
    tmp = Path.join(System.tmp_dir!(), "impl-policy-#{System.unique_integer([:positive])}.yaml")

    entry = ~s(repos: [{name: "#{repo}", test_command: "#{test_command}"#{extra}}])
    File.write!(tmp, File.read!(original) |> String.replace("repos: []", entry))
    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
    end)
  end

  defp stub_github_success do
    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", path} ->
          if path =~ "/comments", do: Req.Test.json(conn, []), else: Req.Test.json(conn, %{})

        {"POST", path} ->
          cond do
            path =~ "/pulls" ->
              conn
              |> Plug.Conn.put_status(201)
              |> Req.Test.json(%{"number" => 55, "html_url" => "https://github.com/x/pull/55"})

            path =~ "/comments" ->
              conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 777})

            true ->
              Plug.Conn.send_resp(conn, 500, "")
          end
      end
    end)
  end

  defp writes_code do
    fn spec ->
      File.write!(Path.join(spec.cwd, "fix.txt"), "the fix")
      {:ok, Harness.Fixtures.runner_result()}
    end
  end

  test "promoted green path: verify → host publish → PR → pr_open", ctx do
    put_repo_policy(ctx.repo, "test -f fix.txt")
    stub_github_success()

    issue =
      issue_fixture(%{repo: ctx.repo, title: "Fix the Widget!", pipeline_state: "plan_ready"})

    run = Harness.Runs.create_run!(%{kind: "plan", status: "succeeded", issue_id: issue.id})

    plan_dir = Path.join(System.tmp_dir!(), "plan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(plan_dir)
    File.write!(Path.join(plan_dir, "PLAN.md"), "# The reviewed plan: touch fix.txt")
    File.write!(Path.join(plan_dir, "CONTEXT.md"), "# ctx")
    on_exit(fn -> File.rm_rf!(plan_dir) end)

    GitHub.record_plan!(%{
      issue_id: issue.id,
      run_id: run.id,
      plan_path: Path.join(plan_dir, "PLAN.md"),
      context_path: Path.join(plan_dir, "CONTEXT.md"),
      branch: "harness/plans/issue-#{issue.number}"
    })

    FakeRunner.script([writes_code()])

    assert :ok = perform_job(ImplementWorker, %{issue_id: issue.id, promoted: true})

    issue = GitHub.get_issue!(issue.id)
    assert issue.pipeline_state == "pr_open"
    assert issue.pr_number == 55
    assert issue.pr_url =~ "/pull/55"

    # the branch really landed on the fixture remote, named per spec §4.3.1
    {refs, 0} = System.cmd("git", ["ls-remote", "file://#{ctx.bare}", "refs/heads/harness/*"])
    assert refs =~ "harness/issue-#{issue.number}-fix-the-widget"

    # the promoted plan is marked, the prompt carried the plan text
    assert Harness.Repo.get_by(Harness.GitHub.Plan, issue_id: issue.id).status == "promoted"
    [spec] = FakeRunner.executed_specs()
    assert spec.kind == :implement
    assert spec.prompt =~ "reviewed plan"
    assert spec.prompt =~ "touch fix.txt"

    assert {:ok, []} = File.ls(Application.fetch_env!(:harness, :workspaces_dir))
  end

  test "red after max_fix_cycles demotes to plan with the failure transcript", ctx do
    put_repo_policy(ctx.repo, "echo boom-#{ctx.repo} && false")
    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "triaged"})

    # initial session + 2 fix cycles (policy max_fix_cycles: 2) = 3 runs
    FakeRunner.script([
      writes_code(),
      fn spec ->
        assert spec.prompt =~ "verification gate rejected"
        assert spec.prompt =~ "boom-"
        {:ok, Harness.Fixtures.runner_result()}
      end,
      writes_code()
    ])

    assert :ok = perform_job(ImplementWorker, %{issue_id: issue.id, promoted: true})

    assert length(FakeRunner.executed_specs()) == 3
    assert GitHub.get_issue!(issue.id).pipeline_state == "triaged"

    assert_enqueued(worker: PlanWorker)

    [job] = all_enqueued(worker: PlanWorker)
    assert job.args["issue_id"] == issue.id
    assert job.args["failure_transcript"] =~ "boom-"
  end

  test "a repo without a test_command demotes straight to plan (no session)", ctx do
    put_repo_policy(ctx.repo, "")
    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "triaged"})
    FakeRunner.script([])

    assert :ok = perform_job(ImplementWorker, %{issue_id: issue.id, promoted: true})

    assert FakeRunner.executed_specs() == []
    assert_enqueued(worker: PlanWorker, args: %{issue_id: issue.id})
  end

  test "non-promoted runs are gated by full_auto mode", ctx do
    put_repo_policy(ctx.repo, "true")
    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "triaged"})
    FakeRunner.script([])

    # policy fixture is plan_only → the auto lane is closed
    assert {:cancel, :mode_not_full_auto} =
             perform_job(ImplementWorker, %{issue_id: issue.id})

    assert FakeRunner.executed_specs() == []
  end

  test "closed or already-PR'd issues are never implemented", ctx do
    put_repo_policy(ctx.repo, "true")
    FakeRunner.script([])

    closed = issue_fixture(%{repo: ctx.repo, state: "closed"})

    assert {:cancel, :issue_no_longer_actionable} =
             perform_job(ImplementWorker, %{issue_id: closed.id, promoted: true})

    pr_open = issue_fixture(%{repo: ctx.repo, pipeline_state: "pr_open"})

    assert {:cancel, :issue_no_longer_actionable} =
             perform_job(ImplementWorker, %{issue_id: pr_open.id, promoted: true})
  end
end
