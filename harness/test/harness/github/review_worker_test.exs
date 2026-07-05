defmodule Harness.GitHub.ReviewWorkerTest do
  use Harness.DataCase, async: false

  alias Harness.GitHub.ReviewWorker
  alias Harness.Runs
  alias Harness.Runs.FakeRunner

  @moduletag :capture_log

  setup do
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

    tmp = Path.join(System.tmp_dir!(), "review-worker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo_name = "owner/rw#{System.unique_integer([:positive])}"
    bare = create_git_remote!(tmp, repo_name)
    Application.put_env(:harness, :github_remote_base, "file://#{tmp}/")

    on_exit(fn ->
      Application.delete_env(:harness, :github_req_options)
      Application.delete_env(:harness, :github_remote_base)
      File.rm_rf!(tmp)
    end)

    %{repo: repo_name, bare: bare, tmp: tmp}
  end

  defp put_repo_policy(repo, test_command) do
    original = Application.fetch_env!(:harness, :policy_path)
    tmp = Path.join(System.tmp_dir!(), "review-policy-#{System.unique_integer([:positive])}.yaml")

    entry = ~s(repos: [{name: "#{repo}", test_command: "#{test_command}"}])
    File.write!(tmp, File.read!(original) |> String.replace("repos: []", entry))
    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
    end)
  end

  # Push a branch to the fixture remote so create_worktree_at! can check it out.
  defp push_harness_branch!(bare, branch) do
    seed = bare <> "-seed-#{System.unique_integer([:positive])}"
    File.mkdir_p!(seed)
    git!(seed, ["clone", "file://" <> bare, seed])
    git!(seed, ["checkout", "-b", branch])
    File.write!(Path.join(seed, "branch_marker.txt"), "review branch")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=test", "-c", "user.email=t@t", "commit", "-m", "branch"])
    git!(seed, ["push", "origin", branch])
    File.rm_rf!(seed)
  end

  defp git!(cd, args) do
    {output, code} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    if code != 0, do: raise("fixture git #{Enum.join(args, " ")} failed: #{output}")
    output
  end

  defp stub_reviews_endpoint(pr_number \\ 55, response_id \\ 100) do
    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", path} when binary_part(path, 0, 1) == "/" ->
          cond do
            path =~ ~r|/pulls/#{pr_number}/reviews| ->
              conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => response_id})

            path =~ "/comments" ->
              Req.Test.json(conn, [])

            true ->
              Req.Test.json(conn, %{})
          end

        {"POST", path} ->
          cond do
            path =~ ~r|/pulls/#{pr_number}/reviews| ->
              conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => response_id})

            path =~ "/comments" ->
              conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

            true ->
              Plug.Conn.send_resp(conn, 500, "")
          end
      end
    end)
  end

  defp no_findings_result do
    fn _spec ->
      {:ok, Harness.Fixtures.runner_result(structured_output: %{"findings" => []})}
    end
  end

  defp findings_result(findings) do
    fn _spec ->
      {:ok, Harness.Fixtures.runner_result(structured_output: %{"findings" => findings})}
    end
  end

  defp writes_fix do
    fn spec ->
      File.write!(Path.join(spec.cwd, "fix_applied.txt"), "fix")
      {:ok, Harness.Fixtures.runner_result()}
    end
  end

  defp sample_finding(confidence \\ 0.9) do
    %{
      "file" => "lib/foo.ex",
      "line" => 10,
      "severity" => "error",
      "summary" => "Wrong return type",
      "fix_hint" => "Return {:ok, value} instead of value",
      "confidence" => confidence
    }
  end

  test "zero findings → clean-verdict COMMENT review posted, no ReviewWorker re-enqueued", ctx do
    put_repo_policy(ctx.repo, "true")
    branch = "harness/issue-1-fix"
    push_harness_branch!(ctx.bare, branch)

    stub_reviews_endpoint(55)

    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "pr_open"})
    FakeRunner.script([no_findings_result()])

    assert :ok =
             perform_job(ReviewWorker, %{
               issue_id: issue.id,
               pr_number: 55,
               round: 0,
               branch: branch
             })

    assert [] = all_enqueued(worker: ReviewWorker)
    assert [spec] = FakeRunner.executed_specs()
    assert spec.kind == :review
    assert spec.output_mode == :json
  end

  test "high-confidence findings → findings COMMENT + fix run + re-review enqueued", ctx do
    put_repo_policy(ctx.repo, "test -f fix_applied.txt")
    branch = "harness/issue-2-fix"
    push_harness_branch!(ctx.bare, branch)
    stub_reviews_endpoint(55)

    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "pr_open"})

    FakeRunner.script([
      findings_result([sample_finding(0.9)]),
      writes_fix()
    ])

    assert :ok =
             perform_job(ReviewWorker, %{
               issue_id: issue.id,
               pr_number: 55,
               round: 0,
               branch: branch
             })

    assert [spec1, spec2] = FakeRunner.executed_specs()
    assert spec1.kind == :review
    assert spec2.kind == :review

    # re-review job enqueued at round 1
    assert [job] = all_enqueued(worker: ReviewWorker)
    assert job.args["round"] == 1
    assert job.args["issue_id"] == issue.id

    # branch was pushed to fixture remote
    {refs, 0} = System.cmd("git", ["ls-remote", "file://#{ctx.bare}", "refs/heads/#{branch}"])
    assert refs =~ branch
  end

  test "loop cap: round >= max_rounds runs review but skips fix and re-review", ctx do
    put_repo_policy(ctx.repo, "true")
    branch = "harness/issue-3-fix"
    push_harness_branch!(ctx.bare, branch)
    stub_reviews_endpoint(55)

    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "pr_open"})

    # max_rounds defaults to 1 in policy; round: 1 equals max_rounds
    FakeRunner.script([findings_result([sample_finding(0.9)])])

    assert :ok =
             perform_job(ReviewWorker, %{
               issue_id: issue.id,
               pr_number: 55,
               round: 1,
               branch: branch
             })

    # only the review spec ran, no fix spec
    assert [spec] = FakeRunner.executed_specs()
    assert spec.kind == :review

    # no new ReviewWorker job
    assert [] = all_enqueued(worker: ReviewWorker)
  end

  test "paused gate → snooze", ctx do
    put_repo_policy(ctx.repo, "true")

    original = Application.fetch_env!(:harness, :policy_path)
    tmp_policy = Path.join(System.tmp_dir!(), "paused-policy-#{System.unique_integer()}.yaml")

    File.write!(
      tmp_policy,
      File.read!(original) |> String.replace("mode: plan_only", "mode: paused")
    )

    Application.put_env(:harness, :policy_path, tmp_policy)
    Harness.Policy.reload()

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp_policy)
    end)

    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "pr_open"})
    FakeRunner.script([])

    assert {:snooze, _} =
             perform_job(ReviewWorker, %{
               issue_id: issue.id,
               pr_number: 55,
               round: 0,
               branch: "harness/issue-4-fix"
             })

    assert [] = FakeRunner.executed_specs()
  end

  test "fix session stays red → no push, no re-review", ctx do
    put_repo_policy(ctx.repo, "false")
    branch = "harness/issue-5-fix"
    push_harness_branch!(ctx.bare, branch)
    stub_reviews_endpoint(55)

    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "pr_open"})

    FakeRunner.script([
      findings_result([sample_finding(0.9)]),
      fn _spec -> {:ok, Harness.Fixtures.runner_result()} end
    ])

    assert :ok =
             perform_job(ReviewWorker, %{
               issue_id: issue.id,
               pr_number: 55,
               round: 0,
               branch: branch
             })

    # no new ReviewWorker
    assert [] = all_enqueued(worker: ReviewWorker)
  end

  test "review runs appear with kind :review in executed specs", ctx do
    put_repo_policy(ctx.repo, "true")
    branch = "harness/issue-6-fix"
    push_harness_branch!(ctx.bare, branch)
    stub_reviews_endpoint(55)

    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "pr_open"})
    FakeRunner.script([no_findings_result()])

    Runs.subscribe()

    assert :ok =
             perform_job(ReviewWorker, %{
               issue_id: issue.id,
               pr_number: 55,
               round: 0,
               branch: branch
             })

    # the run record was created with kind "review"
    run =
      Repo.one(
        from r in Harness.Runs.Run,
          where: r.issue_id == ^issue.id and r.kind == "review",
          limit: 1
      )

    assert run != nil
    assert run.kind == "review"
  end

  test "closed issue is cancelled without running review", ctx do
    closed = issue_fixture(%{repo: ctx.repo, state: "closed", pipeline_state: "pr_open"})
    FakeRunner.script([])

    assert {:cancel, :issue_no_longer_actionable} =
             perform_job(ReviewWorker, %{
               issue_id: closed.id,
               pr_number: 55,
               round: 0,
               branch: "harness/issue-7-fix"
             })

    assert [] = FakeRunner.executed_specs()
  end

  test "MERGEABLE PR: no rebase runs, review executes normally", ctx do
    put_repo_policy(ctx.repo, "true")
    branch = "harness/issue-mergeable-fix"
    push_harness_branch!(ctx.bare, branch)

    Req.Test.stub(__MODULE__, fn conn ->
      path = conn.request_path

      cond do
        conn.method == "GET" and path =~ ~r|/pulls/55$| ->
          Req.Test.json(conn, %{
            "state" => "open",
            "merged" => false,
            "merge_commit_sha" => nil,
            "mergeable" => true,
            "mergeable_state" => "clean",
            "head" => %{"ref" => branch}
          })

        conn.method == "POST" and path =~ ~r|/pulls/55/reviews| ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 1})

        conn.method == "GET" and String.contains?(path, "/comments") ->
          Req.Test.json(conn, [])

        true ->
          Plug.Conn.send_resp(conn, 500, "")
      end
    end)

    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "pr_open"})
    FakeRunner.script([no_findings_result()])

    assert :ok =
             perform_job(ReviewWorker, %{
               issue_id: issue.id,
               pr_number: 55,
               round: 0,
               branch: branch
             })

    assert [spec] = FakeRunner.executed_specs()
    assert spec.kind == :review
  end

  test "human-branch guard: non-harness/* branch skips rebase, review runs normally", ctx do
    put_repo_policy(ctx.repo, "true")
    branch = "feature/human-authored"
    push_harness_branch!(ctx.bare, branch)

    # Stub returns CONFLICTING, but should be ignored for non-harness branches
    Req.Test.stub(__MODULE__, fn conn ->
      path = conn.request_path

      cond do
        conn.method == "GET" and path =~ ~r|/pulls/55$| ->
          Req.Test.json(conn, %{
            "state" => "open",
            "merged" => false,
            "merge_commit_sha" => nil,
            "mergeable" => false,
            "mergeable_state" => "conflicting",
            "head" => %{"ref" => branch}
          })

        conn.method == "POST" and path =~ ~r|/pulls/55/reviews| ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 1})

        conn.method == "GET" and String.contains?(path, "/comments") ->
          Req.Test.json(conn, [])

        true ->
          Plug.Conn.send_resp(conn, 500, "")
      end
    end)

    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "pr_open"})
    FakeRunner.script([no_findings_result()])

    assert :ok =
             perform_job(ReviewWorker, %{
               issue_id: issue.id,
               pr_number: 55,
               round: 0,
               branch: branch
             })

    # Review ran normally (no rebase attempted)
    assert [spec] = FakeRunner.executed_specs()
    assert spec.kind == :review
  end

  test "escalation: conflict resolution fails → stamped comment posted, no push", ctx do
    put_repo_policy(ctx.repo, "true")
    branch = "harness/issue-escalate-fix"

    # Set up a real conflicting branch: main and branch both modify the same file
    seed = ctx.bare <> "-escseed-#{System.unique_integer([:positive])}"
    File.mkdir_p!(seed)
    git!(seed, ["clone", "file://" <> ctx.bare, seed])

    File.write!(Path.join(seed, "conflict_escalate.txt"), "main version\n")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=test", "-c", "user.email=t@t", "commit", "-m", "main adds"])
    git!(seed, ["push", "origin", "main"])

    git!(seed, ["checkout", "HEAD~1"])
    git!(seed, ["checkout", "-b", branch])
    File.write!(Path.join(seed, "conflict_escalate.txt"), "branch version\n")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=test", "-c", "user.email=t@t", "commit", "-m", "branch adds"])
    git!(seed, ["push", "origin", branch])
    File.rm_rf!(seed)

    comment_posted = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      path = conn.request_path

      cond do
        conn.method == "GET" and path =~ ~r|/pulls/55$| ->
          Req.Test.json(conn, %{
            "state" => "open",
            "merged" => false,
            "merge_commit_sha" => nil,
            "mergeable" => false,
            "mergeable_state" => "conflicting",
            "head" => %{"ref" => branch}
          })

        conn.method == "POST" and String.contains?(path, "/comments") ->
          :counters.add(comment_posted, 1, 1)
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 99})

        true ->
          Plug.Conn.send_resp(conn, 500, "")
      end
    end)

    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "pr_open"})

    # Conflict resolution runner fails
    FakeRunner.script([fn _spec -> {:error, :resolution_failed} end])

    assert :ok =
             perform_job(ReviewWorker, %{
               issue_id: issue.id,
               pr_number: 55,
               round: 0,
               branch: branch
             })

    # Escalation comment was posted
    assert :counters.get(comment_posted, 1) >= 1
    # No review spec ran — only the resolution runner was called
    assert [resolution_spec] = FakeRunner.executed_specs()
    assert resolution_spec.output_mode == :stream_json
    # No new ReviewWorker jobs
    assert [] = all_enqueued(worker: ReviewWorker)
  end

  test "low-confidence findings are not actionable (no fix cycle)", ctx do
    put_repo_policy(ctx.repo, "true")
    branch = "harness/issue-8-fix"
    push_harness_branch!(ctx.bare, branch)
    stub_reviews_endpoint(55)

    issue = issue_fixture(%{repo: ctx.repo, pipeline_state: "pr_open"})

    # confidence 0.3 is below the default confidence_floor of 0.7
    FakeRunner.script([findings_result([sample_finding(0.3)])])

    assert :ok =
             perform_job(ReviewWorker, %{
               issue_id: issue.id,
               pr_number: 55,
               round: 0,
               branch: branch
             })

    # only the review spec ran (no fix)
    assert [_spec] = FakeRunner.executed_specs()
    # no re-review
    assert [] = all_enqueued(worker: ReviewWorker)
  end
end
