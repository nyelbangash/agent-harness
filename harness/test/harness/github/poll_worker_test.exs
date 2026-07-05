defmodule Harness.GitHub.PollWorkerTest do
  use Harness.DataCase, async: false

  alias Harness.GitHub
  alias Harness.GitHub.{PollWorker, TriageWorker}

  @moduletag :capture_log

  @repo "owner/polled"

  setup do
    :persistent_term.erase({PollWorker, :login})
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})

    original = Application.fetch_env!(:harness, :policy_path)
    tmp = Path.join(System.tmp_dir!(), "poll-policy-#{System.unique_integer([:positive])}.yaml")

    File.write!(
      tmp,
      File.read!(original) |> String.replace("repos: []", ~s(repos: ["#{@repo}"]))
    )

    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()

    on_exit(fn ->
      Application.delete_env(:harness, :github_req_options)
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
      :persistent_term.erase({PollWorker, :login})
    end)

    :ok
  end

  defp stub_issues(issues, opts \\ []) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/user" ->
          Req.Test.json(conn, %{"login" => "nyelbangash"})

        "/repos/" <> _ ->
          if opts[:not_modified] do
            Plug.Conn.send_resp(conn, 304, "")
          else
            conn
            |> Plug.Conn.put_resp_header("etag", ~s(W/"tag-1"))
            |> Req.Test.json(issues)
          end
      end
    end)
  end

  test "a new assigned issue is mirrored and triage is enqueued" do
    stub_issues([gh_issue_payload(number: 7, title: "New bug")])

    assert :ok = perform_job(PollWorker, %{})

    issue = GitHub.get_issue_by(@repo, 7)
    assert issue.title == "New bug"
    assert issue.pipeline_state == "incoming"
    assert_enqueued(worker: TriageWorker, args: %{issue_id: issue.id})

    state = GitHub.repo_state(@repo)
    assert state.etag == ~s(W/"tag-1")
    assert state.last_status == 200
  end

  test "human-only labelled issues are skipped with no triage" do
    stub_issues([
      gh_issue_payload(number: 8, labels: [%{"name" => "human-only"}])
    ])

    assert :ok = perform_job(PollWorker, %{})

    assert GitHub.get_issue_by(@repo, 8).pipeline_state == "skipped"
    refute_enqueued(worker: TriageWorker)
  end

  test "a 304 does nothing but record the poll" do
    stub_issues([], not_modified: true)

    assert :ok = perform_job(PollWorker, %{})

    assert GitHub.repo_state(@repo).last_status == 304
    refute_enqueued(worker: TriageWorker)
  end

  test "an upstream update re-triages an issue parked in a restartable state" do
    stub_issues([gh_issue_payload(number: 9, updated_at: "2026-07-04T12:00:00Z")])
    assert :ok = perform_job(PollWorker, %{})
    issue = GitHub.get_issue_by(@repo, 9)

    # drain the first enqueue and settle the issue
    GitHub.transition!(issue, "plan_ready")
    Harness.Repo.delete_all(Oban.Job)

    # poll again with a newer updated_at → re-enqueued
    stub_issues([
      gh_issue_payload(number: 9, id: issue.github_id, updated_at: "2026-07-04T13:00:00Z")
    ])

    reset_poll_clock()
    assert :ok = perform_job(PollWorker, %{})

    assert_enqueued(worker: TriageWorker, args: %{issue_id: issue.id})
    assert GitHub.get_issue_by(@repo, 9).pipeline_state == "incoming"
  end

  test "an unchanged issue is not re-triaged" do
    payload = gh_issue_payload(number: 10, updated_at: "2026-07-04T12:00:00Z")
    stub_issues([payload])
    assert :ok = perform_job(PollWorker, %{})
    issue = GitHub.get_issue_by(@repo, 10)
    GitHub.transition!(issue, "plan_ready")
    Harness.Repo.delete_all(Oban.Job)

    stub_issues([Map.put(payload, "id", issue.github_id)])
    reset_poll_clock()
    assert :ok = perform_job(PollWorker, %{})

    refute_enqueued(worker: TriageWorker)
    assert GitHub.get_issue_by(@repo, 10).pipeline_state == "plan_ready"
  end

  test "plan comment self-acknowledge: stored timestamp advances, next poll enqueues nothing" do
    stub_issues([gh_issue_payload(number: 20, updated_at: "2026-07-04T12:00:00Z")])
    assert :ok = perform_job(PollWorker, %{})
    issue = GitHub.get_issue_by(@repo, 20)
    GitHub.transition!(issue, "plan_ready")
    Harness.Repo.delete_all(Oban.Job)

    # Simulate what PlanWorker does: advance github_updated_at to comment time
    GitHub.acknowledge_comment_timestamp!(issue, "2026-07-04T13:00:00Z")

    # Poll with the same updated_at as what we just stored — no delta
    stub_issues([
      gh_issue_payload(number: 20, id: issue.github_id, updated_at: "2026-07-04T13:00:00Z")
    ])

    reset_poll_clock()
    assert :ok = perform_job(PollWorker, %{})

    refute_enqueued(worker: Harness.GitHub.TriageWorker)
    assert GitHub.get_issue_by(@repo, 20).pipeline_state == "plan_ready"
  end

  test "belt-and-braces: harness-authored newest comment suppresses re-triage" do
    stub_issues([gh_issue_payload(number: 21, updated_at: "2026-07-04T12:00:00Z")])
    assert :ok = perform_job(PollWorker, %{})
    issue = GitHub.get_issue_by(@repo, 21)
    GitHub.transition!(issue, "plan_ready")
    Harness.Repo.delete_all(Oban.Job)

    harness_body = Harness.GitHub.Provenance.stamp("plan content", "plan", "run-1")

    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        conn.request_path == "/user" ->
          Req.Test.json(conn, %{"login" => "nyelbangash"})

        conn.method == "GET" and not String.contains?(conn.request_path, "comments") ->
          conn
          |> Plug.Conn.put_resp_header("etag", ~s(W/"tag-2"))
          |> Req.Test.json([
            gh_issue_payload(number: 21, id: issue.github_id, updated_at: "2026-07-04T13:00:00Z")
          ])

        true ->
          Req.Test.json(conn, [
            %{"body" => harness_body, "created_at" => "2026-07-04T13:00:00Z", "id" => 100}
          ])
      end
    end)

    reset_poll_clock()
    assert :ok = perform_job(PollWorker, %{})

    refute_enqueued(worker: Harness.GitHub.TriageWorker)
  end

  test "belt-and-braces: human newest comment still triggers re-triage" do
    stub_issues([gh_issue_payload(number: 22, updated_at: "2026-07-04T12:00:00Z")])
    assert :ok = perform_job(PollWorker, %{})
    issue = GitHub.get_issue_by(@repo, 22)
    GitHub.transition!(issue, "plan_ready")
    Harness.Repo.delete_all(Oban.Job)

    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        conn.request_path == "/user" ->
          Req.Test.json(conn, %{"login" => "nyelbangash"})

        conn.method == "GET" and not String.contains?(conn.request_path, "comments") ->
          conn
          |> Plug.Conn.put_resp_header("etag", ~s(W/"tag-3"))
          |> Req.Test.json([
            gh_issue_payload(number: 22, id: issue.github_id, updated_at: "2026-07-04T13:00:00Z")
          ])

        true ->
          Req.Test.json(conn, [
            %{
              "body" => "human comment, no provenance marker",
              "created_at" => "2026-07-04T13:00:00Z",
              "id" => 101
            }
          ])
      end
    end)

    reset_poll_clock()
    assert :ok = perform_job(PollWorker, %{})

    assert_enqueued(worker: Harness.GitHub.TriageWorker, args: %{issue_id: issue.id})
  end

  test "issues that vanish from the open list are closed out" do
    stub_issues([gh_issue_payload(number: 11)])
    assert :ok = perform_job(PollWorker, %{})
    issue = GitHub.get_issue_by(@repo, 11)
    GitHub.transition!(issue, "plan_ready")

    stub_issues([])
    reset_poll_clock()
    assert :ok = perform_job(PollWorker, %{})

    issue = GitHub.get_issue_by(@repo, 11)
    assert issue.state == "closed"
    assert issue.pipeline_state == "done"
  end

  test "polls are throttled by github.poll_minutes" do
    stub_issues([gh_issue_payload(number: 12)])
    assert :ok = perform_job(PollWorker, %{})
    assert GitHub.get_issue_by(@repo, 12)

    # immediately re-polling is not due — a request now would raise (stub
    # replaced with one that fails the test if called for the repo)
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/user" -> Req.Test.json(conn, %{"login" => "nyelbangash"})
        path -> flunk("unexpected poll request to #{path}")
      end
    end)

    assert :ok = perform_job(PollWorker, %{})
  end

  defp reset_poll_clock do
    state = GitHub.repo_state(@repo)

    GitHub.update_repo_state!(state, %{
      last_polled_at: DateTime.add(DateTime.utc_now(), -600, :second)
    })
  end
end
