defmodule Harness.GitHub.ProjectPollWorkerTest do
  use Harness.DataCase, async: false

  import ExUnit.CaptureLog

  alias Harness.GitHub
  alias Harness.GitHub.{ImplementWorker, ProjectPollWorker, TriageWorker}

  @moduletag :capture_log

  @owner "someorg"
  @number 7
  @repo "someorg/board-repo"

  setup do
    :persistent_term.erase({ProjectPollWorker, :login, @owner})
    :persistent_term.erase({ProjectPollWorker, :logged_plan_only, @repo})
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})

    original = Application.fetch_env!(:harness, :policy_path)
    base_content = File.read!(original)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "project-poll-policy-#{System.unique_integer([:positive])}.yaml"
      )

    write_policy!(base_content, tmp, :assignee)

    on_exit(fn ->
      Application.delete_env(:harness, :github_req_options)
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
      :persistent_term.erase({ProjectPollWorker, :login, @owner})
      :persistent_term.erase({ProjectPollWorker, :logged_plan_only, @repo})
    end)

    %{base_content: base_content, tmp: tmp}
  end

  defp write_policy!(base_content, tmp, trigger) do
    content =
      String.replace(
        base_content,
        "poll_minutes: 2\n",
        "poll_minutes: 2\n#{project_yaml(trigger)}"
      )

    File.write!(tmp, content)
    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()
  end

  defp project_yaml(:assignee) do
    [
      "  projects:",
      "    - owner: #{@owner}",
      "      number: #{@number}",
      "      trigger: assignee",
      ""
    ]
    |> Enum.join("\n")
  end

  defp project_yaml({:field, name, value}) do
    [
      "  projects:",
      "    - owner: #{@owner}",
      "      number: #{@number}",
      "      trigger:",
      "        field: #{name}",
      "        value: #{value}",
      ""
    ]
    |> Enum.join("\n")
  end

  defp stub_project(items_nodes, opts \\ []) do
    login = opts[:login] || "nyelbangash"

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/user" ->
          Req.Test.json(conn, %{"login" => login})

        "/repos/" <> _ ->
          # newest_issue_comment, called by PollWorker.handle_issue/2's
          # harness-caused-update guard on the :updated re-triage path
          Req.Test.json(conn, [])

        "/graphql" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          body = Jason.decode!(raw)

          if body["query"] =~ "organization(login" do
            Req.Test.json(conn, %{
              "data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_1"}}}
            })
          else
            Req.Test.json(conn, %{
              "data" => %{
                "node" => %{
                  "items" => %{
                    "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                    "nodes" => items_nodes
                  }
                }
              }
            })
          end
      end
    end)
  end

  defp issue_node(attrs) do
    number = Keyword.fetch!(attrs, :number)
    repo = Keyword.fetch!(attrs, :repo)

    %{
      "content" => %{
        "__typename" => "Issue",
        "number" => number,
        "title" => attrs[:title] || "board issue #{number}",
        "body" => attrs[:body] || "board issue body",
        "state" => attrs[:state] || "OPEN",
        "url" => "https://github.com/#{repo}/issues/#{number}",
        "databaseId" => attrs[:github_id] || System.unique_integer([:positive]),
        "updatedAt" => attrs[:updated_at] || "2026-07-04T12:00:00Z",
        "labels" => %{"nodes" => Enum.map(attrs[:labels] || [], &%{"name" => &1})},
        "author" => %{"login" => attrs[:author] || "someone"},
        "comments" => %{"totalCount" => 0},
        "repository" => %{"nameWithOwner" => repo},
        "assignees" => %{"nodes" => Enum.map(attrs[:assignees] || [], &%{"login" => &1})}
      },
      "fieldValues" => %{
        "nodes" =>
          Enum.map(attrs[:field_values] || [], fn {field, value} ->
            %{
              "__typename" => "ProjectV2ItemFieldSingleSelectValue",
              "name" => value,
              "field" => %{"name" => field}
            }
          end)
      }
    }
  end

  defp pr_node(number) do
    %{
      "content" => %{"__typename" => "PullRequest", "number" => number},
      "fieldValues" => %{"nodes" => []}
    }
  end

  defp draft_node(title) do
    %{
      "content" => %{"__typename" => "DraftIssue", "title" => title},
      "fieldValues" => %{"nodes" => []}
    }
  end

  defp reset_poll_clock do
    state = GitHub.project_state(@owner, @number)

    GitHub.update_project_state!(state, %{
      last_polled_at: DateTime.add(DateTime.utc_now(), -600, :second)
    })
  end

  test "an issue item matching the assignee trigger upserts and enqueues triage" do
    stub_project([issue_node(number: 101, repo: @repo, assignees: ["nyelbangash"])])

    assert :ok = perform_job(ProjectPollWorker, %{})

    issue = GitHub.get_issue_by(@repo, 101)
    assert issue
    assert issue.pipeline_state == "incoming"
    assert_enqueued(worker: TriageWorker, args: %{issue_id: issue.id})
  end

  test "an issue item whose assignee does not match the trigger is excluded" do
    stub_project([issue_node(number: 102, repo: @repo, assignees: ["someone_else"])])

    assert :ok = perform_job(ProjectPollWorker, %{})

    refute GitHub.get_issue_by(@repo, 102)
    refute_enqueued(worker: TriageWorker)
  end

  test "a pull request item is ignored" do
    stub_project([pr_node(55)])

    assert :ok = perform_job(ProjectPollWorker, %{})

    assert Harness.Repo.aggregate(Harness.GitHub.Issue, :count) == 0
    refute_enqueued(worker: TriageWorker)
  end

  test "a draft issue item is skipped with a logged notice, no row created" do
    stub_project([draft_node("a draft idea")])

    log = capture_log(fn -> assert :ok = perform_job(ProjectPollWorker, %{}) end)

    assert log =~ "skipping draft issue"
    assert Harness.Repo.aggregate(Harness.GitHub.Issue, :count) == 0
    refute_enqueued(worker: TriageWorker)
  end

  test "an issue item matching a field trigger upserts", %{base_content: base_content, tmp: tmp} do
    write_policy!(base_content, tmp, {:field, "Status", "Ready"})

    stub_project([
      issue_node(number: 103, repo: @repo, field_values: [{"Status", "Ready"}])
    ])

    assert :ok = perform_job(ProjectPollWorker, %{})

    assert GitHub.get_issue_by(@repo, 103)
  end

  test "an issue item whose field value does not match the trigger is excluded", %{
    base_content: base_content,
    tmp: tmp
  } do
    write_policy!(base_content, tmp, {:field, "Status", "Ready"})

    stub_project([
      issue_node(number: 104, repo: @repo, field_values: [{"Status", "Backlog"}])
    ])

    assert :ok = perform_job(ProjectPollWorker, %{})

    refute GitHub.get_issue_by(@repo, 104)
  end

  test "a project issue in a repo without a github.repos entry is plan-lane only, notice logged once" do
    stub_project([issue_node(number: 105, repo: @repo, assignees: ["nyelbangash"])])

    log1 = capture_log(fn -> assert :ok = perform_job(ProjectPollWorker, %{}) end)
    assert log1 =~ "plan-lane only (no test_command)"

    reset_poll_clock()

    stub_project([
      issue_node(
        number: 105,
        repo: @repo,
        assignees: ["nyelbangash"],
        updated_at: "2026-07-04T13:00:00Z"
      )
    ])

    log2 = capture_log(fn -> assert :ok = perform_job(ProjectPollWorker, %{}) end)
    refute log2 =~ "plan-lane only"

    refute_enqueued(worker: ImplementWorker)
  end

  test "idempotency: two consecutive polls of the same board enqueue no duplicate triage job" do
    stub_project([
      issue_node(
        number: 106,
        repo: @repo,
        assignees: ["nyelbangash"],
        updated_at: "2026-07-04T12:00:00Z",
        github_id: 9999
      )
    ])

    assert :ok = perform_job(ProjectPollWorker, %{})
    issue = GitHub.get_issue_by(@repo, 106)
    assert_enqueued(worker: TriageWorker, args: %{issue_id: issue.id})

    Harness.Repo.delete_all(Oban.Job)
    reset_poll_clock()

    stub_project([
      issue_node(
        number: 106,
        repo: @repo,
        assignees: ["nyelbangash"],
        updated_at: "2026-07-04T12:00:00Z",
        github_id: 9999
      )
    ])

    assert :ok = perform_job(ProjectPollWorker, %{})
    refute_enqueued(worker: TriageWorker)
  end
end
