defmodule Harness.GitHub.RespondWorkerTest do
  use Harness.DataCase, async: false

  alias Harness.GitHub
  alias Harness.GitHub.{PrCommentHandle, RespondWorker}
  alias Harness.Runs.FakeRunner

  @moduletag :capture_log

  setup do
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

    tmp = Path.join(System.tmp_dir!(), "respond-worker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo_name = "owner/rw#{System.unique_integer([:positive])}"
    bare = create_git_remote!(tmp, repo_name)
    Application.put_env(:harness, :github_remote_base, "file://#{tmp}/")

    on_exit(fn ->
      Application.delete_env(:harness, :github_req_options)
      Application.delete_env(:harness, :github_remote_base)
      File.rm_rf!(tmp)
    end)

    %{repo: repo_name, bare: bare}
  end

  defp put_repo_policy(repo, test_command) do
    original = Application.fetch_env!(:harness, :policy_path)
    tmp_policy = Path.join(System.tmp_dir!(), "respond-policy-#{System.unique_integer([:positive])}.yaml")
    entry = ~s(repos: [{name: "#{repo}", test_command: "#{test_command}"}])
    File.write!(tmp_policy, File.read!(original) |> String.replace("repos: []", entry))
    Application.put_env(:harness, :policy_path, tmp_policy)
    Harness.Policy.reload()

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp_policy)
    end)
  end

  defp create_pr_branch!(bare, branch) do
    seed = Path.join(System.tmp_dir!(), "prseed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(seed)

    git_cmd!(seed, ["clone", "file://#{bare}", seed])
    git_cmd!(seed, ["checkout", "-b", branch])
    File.write!(Path.join(seed, "pr_feature.txt"), "initial pr content\n")
    git_cmd!(seed, ["add", "-A"])
    git_cmd!(seed, ["-c", "user.name=fixture", "-c", "user.email=fixture@test", "commit", "-m", "pr commit"])
    git_cmd!(seed, ["push", "origin", branch])
    File.rm_rf!(seed)
  end

  defp git_cmd!(cd, args) do
    {output, code} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    if code != 0, do: raise("git #{Enum.join(args, " ")} failed: #{output}")
    output
  end

  defp setup_issue_with_pr(ctx, issue_number, pr_number) do
    branch = "harness/issue-#{issue_number}-fix-the-widget"
    create_pr_branch!(ctx.bare, branch)

    issue_fixture(%{
      repo: ctx.repo,
      number: issue_number,
      title: "Fix the widget",
      pipeline_state: "pr_open",
      pr_number: pr_number
    })
  end

  defp insert_handle(issue, comment_type, comment_id) do
    {:inserted, handle} =
      GitHub.maybe_insert_pr_comment_handle!(%{
        repo: issue.repo,
        pr_number: issue.pr_number,
        comment_id: comment_id,
        comment_type: comment_type
      })

    handle
  end

  defp pre_flight_fix do
    fn _spec ->
      {:ok, Harness.Fixtures.runner_result(structured_output: %{"action" => "fix", "reason" => "in scope"})}
    end
  end

  defp pre_flight_decline do
    fn _spec ->
      {:ok, Harness.Fixtures.runner_result(structured_output: %{"action" => "decline_with_reason", "reason" => "out of scope for this branch"})}
    end
  end

  defp writes_fix do
    fn spec ->
      File.write!(Path.join(spec.cwd, "fix.txt"), "the fix")
      {:ok, Harness.Fixtures.runner_result(result_text: "Fixed the widget.")}
    end
  end

  test "fix path: verify passes → push commit and stamped reply", ctx do
    put_repo_policy(ctx.repo, "test -f fix.txt")
    issue_number = System.unique_integer([:positive])
    issue = setup_issue_with_pr(ctx, issue_number, 100)
    handle = insert_handle(issue, "review", 5001)

    captured_bodies = start_supervised!({Agent, fn -> [] end})

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", _} ->
          Req.Test.json(conn, [])

        {"POST", _} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          Agent.update(captured_bodies, &[Jason.decode!(raw)["body"] | &1])

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"id" => 999, "created_at" => "2026-07-06T10:00:00Z"})
      end
    end)

    FakeRunner.script([pre_flight_fix(), writes_fix()])

    assert :ok =
             perform_job(RespondWorker, %{
               pr_comment_handle_id: handle.id,
               issue_id: issue.id,
               comment_body: "please add a type annotation here",
               comment_path: "lib/widget.ex",
               comment_line: 10,
               comment_diff_hunk: "@@ -1 +1 @@\n-def foo, do: nil\n+def foo :: term, do: nil"
             })

    handle = Harness.Repo.get!(PrCommentHandle, handle.id)
    assert handle.action == "fix"
    assert not is_nil(handle.run_id)

    branch = "harness/issue-#{issue_number}-fix-the-widget"
    {refs, 0} = System.cmd("git", ["ls-remote", "file://#{ctx.bare}", "refs/heads/#{branch}"])
    assert refs =~ branch

    [reply | _] = Agent.get(captured_bodies, & &1)
    assert Harness.GitHub.Provenance.harness_authored?(reply)
    assert reply =~ "fix"
  end

  test "decline path: pre-flight returns decline_with_reason, no push", ctx do
    put_repo_policy(ctx.repo, "true")
    issue_number = System.unique_integer([:positive])
    issue = setup_issue_with_pr(ctx, issue_number, 101)
    handle = insert_handle(issue, "issue", 5002)

    captured_bodies = start_supervised!({Agent, fn -> [] end})

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", _} ->
          Req.Test.json(conn, [])

        {"POST", _} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          Agent.update(captured_bodies, &[Jason.decode!(raw)["body"] | &1])

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"id" => 888, "created_at" => "2026-07-06T10:00:00Z"})
      end
    end)

    FakeRunner.script([pre_flight_decline()])

    assert :ok =
             perform_job(RespondWorker, %{
               pr_comment_handle_id: handle.id,
               issue_id: issue.id,
               comment_body: "can you rewrite the entire auth system",
               comment_path: nil,
               comment_line: nil,
               comment_diff_hunk: nil
             })

    handle = Harness.Repo.get!(PrCommentHandle, handle.id)
    assert handle.action == "decline_with_reason"

    [reply | _] = Agent.get(captured_bodies, & &1)
    assert Harness.GitHub.Provenance.harness_authored?(reply)
    assert reply =~ "out of scope for this branch"

    assert length(FakeRunner.executed_specs()) == 1
  end

  test "verify failure: no push, explains failure in stamped reply", ctx do
    put_repo_policy(ctx.repo, "test -f this_file_does_not_exist.txt")
    issue_number = System.unique_integer([:positive])
    issue = setup_issue_with_pr(ctx, issue_number, 102)
    handle = insert_handle(issue, "review", 5003)

    captured_bodies = start_supervised!({Agent, fn -> [] end})

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", _} ->
          Req.Test.json(conn, [])

        {"POST", _} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          Agent.update(captured_bodies, &[Jason.decode!(raw)["body"] | &1])

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"id" => 999, "created_at" => "2026-07-06T10:00:00Z"})
      end
    end)

    FakeRunner.script([
      pre_flight_fix(),
      fn spec ->
        File.write!(Path.join(spec.cwd, "unrelated.txt"), "won't satisfy test_command")
        {:ok, Harness.Fixtures.runner_result(result_text: "made some changes")}
      end
    ])

    assert :ok =
             perform_job(RespondWorker, %{
               pr_comment_handle_id: handle.id,
               issue_id: issue.id,
               comment_body: "please fix this",
               comment_path: "lib/widget.ex",
               comment_line: 5,
               comment_diff_hunk: nil
             })

    handle = Harness.Repo.get!(PrCommentHandle, handle.id)
    assert handle.action == "decline_with_reason"

    [reply | _] = Agent.get(captured_bodies, & &1)
    assert Harness.GitHub.Provenance.harness_authored?(reply)
    assert reply =~ "verification failed"
  end

  test "issue not in pr_open state cancels immediately", ctx do
    issue_number = System.unique_integer([:positive])

    issue =
      issue_fixture(%{
        repo: ctx.repo,
        number: issue_number,
        pipeline_state: "triaged",
        pr_number: nil
      })

    {:inserted, handle} =
      GitHub.maybe_insert_pr_comment_handle!(%{
        repo: issue.repo,
        pr_number: 200,
        comment_id: 6001,
        comment_type: "review"
      })

    FakeRunner.script([])

    assert {:cancel, :issue_no_longer_actionable} =
             perform_job(RespondWorker, %{
               pr_comment_handle_id: handle.id,
               issue_id: issue.id,
               comment_body: "fix this",
               comment_path: nil,
               comment_line: nil,
               comment_diff_hunk: nil
             })

    assert FakeRunner.executed_specs() == []
  end
end
