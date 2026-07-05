defmodule Harness.Ideation.PromoteWorkerTest do
  use Harness.DataCase, async: false

  alias Harness.Ideation
  alias Harness.Ideation.PromoteWorker
  alias Harness.Runs.FakeRunner

  @moduletag :capture_log

  @canned_contract %{
    "epic" => %{"title" => "Epic: Better Widget", "body" => "## Motivation\n\nImprove the widget."},
    "children" => [
      %{
        "title" => "Add widget validation",
        "body" =>
          "## What\n\nValidate widget inputs.\n\n## Acceptance\n\nTests pass.\n\n## Non-goals\n\nNo UI changes."
      },
      %{
        "title" => "Add widget telemetry",
        "body" =>
          "## What\n\nEmit telemetry events.\n\n## Acceptance\n\nTests pass.\n\n## Non-goals\n\nNo dashboards."
      }
    ]
  }

  setup do
    # Mock GitHub API
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "unexpected") end)

    on_exit(fn ->
      Application.delete_env(:harness, :github_req_options)
    end)

    :ok
  end

  defp policy_with_repo(repo_name) do
    original = Application.fetch_env!(:harness, :policy_path)

    tmp =
      Path.join(System.tmp_dir!(), "promote-policy-#{System.unique_integer([:positive])}.yaml")

    File.write!(
      tmp,
      File.read!(original)
      |> String.replace("repos: []", "repos:\n  - #{repo_name}")
    )

    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
    end)

    tmp
  end

  defp paused_policy do
    original = Application.fetch_env!(:harness, :policy_path)

    tmp =
      Path.join(System.tmp_dir!(), "paused-policy-#{System.unique_integer([:positive])}.yaml")

    File.write!(
      tmp,
      File.read!(original) |> String.replace("mode: plan_only", "mode: paused")
    )

    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
    end)
  end

  defp stub_github(captured) do
    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/user"} ->
          Req.Test.json(conn, %{"login" => "testuser"})

        {"POST", "/repos/" <> _} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          payload = Jason.decode!(raw)
          Agent.update(captured, fn list -> list ++ [{conn.request_path, payload}] end)
          issue_number = length(Agent.get(captured, & &1))

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "number" => issue_number,
            "html_url" =>
              "https://github.com/owner/repo/issues/#{issue_number}"
          })

        {"PATCH", "/repos/" <> _} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          payload = Jason.decode!(raw)
          Agent.update(captured, fn list -> list ++ [{"PATCH", payload}] end)
          Req.Test.json(conn, %{"number" => 1, "html_url" => "..."})

        _ ->
          Plug.Conn.send_resp(conn, 500, "unexpected #{conn.method} #{conn.request_path}")
      end
    end)
  end

  test "happy path: creates epic + children, stamps provenance, self-assigns, backfills task list" do
    policy_with_repo("owner/repo")
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 60})

    idea =
      Ideation.add_child!(
        session,
        root,
        %{title: "Good Idea", summary: "do the thing", score: 8.0},
        "# artifact"
      )

    captured = start_supervised!({Agent, fn -> [] end})
    stub_github(captured)

    FakeRunner.script([
      {:ok,
       %Harness.Runs.Runner.Result{
         run_id: 0,
         subtype: "success",
         structured_output: @canned_contract
       }}
    ])

    assert :ok = perform_job(PromoteWorker, %{
                   session_id: session.id,
                   idea_id: idea.id,
                   target_repo: "owner/repo"
                 })

    calls = Agent.get(captured, & &1)

    # epic POST + 2 child POSTs + 1 epic PATCH = 4 calls
    assert length(calls) == 4

    # Epic was created first
    {epic_path, epic_payload} = Enum.at(calls, 0)
    assert epic_path =~ "/issues"
    assert epic_payload["title"] == "Epic: Better Widget"
    assert epic_payload["assignees"] == ["testuser"]
    # provenance marker present
    assert epic_payload["body"] =~ "<!-- harness:v1"

    # First child links the epic
    {_path, child1_payload} = Enum.at(calls, 1)
    assert child1_payload["title"] == "Add widget validation"
    assert child1_payload["assignees"] == ["testuser"]
    assert child1_payload["body"] =~ "Part of epic:"
    assert child1_payload["body"] =~ "<!-- harness:v1"

    # Second child
    {_path, child2_payload} = Enum.at(calls, 2)
    assert child2_payload["title"] == "Add widget telemetry"

    # Epic PATCH backfills task list
    {"PATCH", patch_payload} = Enum.at(calls, 3)
    assert patch_payload["body"] =~ "## Issues"
    assert patch_payload["body"] =~ "- [ ]"
    assert patch_payload["body"] =~ "<!-- harness:v1"

    # idea updated with epic URL
    updated_idea = Ideation.get_idea!(idea.id)
    assert updated_idea.promoted_epic_url =~ "issues/1"
    assert updated_idea.promoted_epic_number == 1
  end

  test "policy guard: rejects non-policy repo" do
    # default fixture policy has repos: []
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 60})
    idea = Ideation.add_child!(session, root, %{title: "Idea", summary: "s", score: 8.0}, "")

    FakeRunner.script([])

    assert {:cancel, :target_repo_not_in_policy} =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: "not/allowed"
             })

    # no runner was invoked
    assert FakeRunner.executed_specs() == []
  end

  test "policy guard: rejects paused mode" do
    policy_with_repo("owner/repo")
    paused_policy()

    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 60})
    idea = Ideation.add_child!(session, root, %{title: "Idea", summary: "s", score: 8.0}, "")

    FakeRunner.script([])

    assert {:cancel, :paused} =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: "owner/repo"
             })

    assert FakeRunner.executed_specs() == []
  end

  test "malformed contract: no GitHub calls when structured_output missing" do
    policy_with_repo("owner/repo")
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 60})
    idea = Ideation.add_child!(session, root, %{title: "Idea", summary: "s", score: 8.0}, "")

    captured = start_supervised!({Agent, fn -> [] end})
    stub_github(captured)

    FakeRunner.script([
      {:ok,
       %Harness.Runs.Runner.Result{
         run_id: 0,
         subtype: "success",
         structured_output: nil
       }}
    ])

    assert {:error, :malformed_contract} =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: "owner/repo"
             })

    # no GitHub calls made
    assert Agent.get(captured, & &1) == []
  end

  test "child failure is commented on the epic, does not delete the created epic" do
    policy_with_repo("owner/repo")
    {session, root} = Ideation.start_session(%{seed_prompt: "seed", budget_minutes: 60})
    idea = Ideation.add_child!(session, root, %{title: "Idea", summary: "s", score: 8.0}, "")

    call_count = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/user"} ->
          Req.Test.json(conn, %{"login" => "testuser"})

        {"POST", "/repos/owner/repo/issues"} ->
          Agent.update(call_count, &(&1 + 1))
          count = Agent.get(call_count, & &1)

          if count == 1 do
            # epic succeeds
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "number" => 10,
              "html_url" => "https://github.com/owner/repo/issues/10"
            })
          else
            # child 1 fails
            conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "invalid"})
          end

        {"POST", "/repos/owner/repo/issues/10/comments"} ->
          # failure comment on epic
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"id" => 99, "created_at" => "2026-07-05T12:00:00Z"})

        {"PATCH", _} ->
          Req.Test.json(conn, %{"number" => 10, "html_url" => "..."})

        _ ->
          Plug.Conn.send_resp(conn, 500, "unexpected")
      end
    end)

    FakeRunner.script([
      {:ok,
       %Harness.Runs.Runner.Result{
         run_id: 0,
         subtype: "success",
         structured_output: %{
           "epic" => %{"title" => "E", "body" => "body"},
           "children" => [%{"title" => "C1", "body" => "b1"}]
         }
       }}
    ])

    # job should still succeed (failure commented, not fatal)
    assert :ok =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: "owner/repo"
             })

    # epic was recorded despite child failure
    updated = Ideation.get_idea!(idea.id)
    assert updated.promoted_epic_url =~ "issues/10"
  end
end
