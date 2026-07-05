defmodule Harness.Ideation.PromoteWorkerTest do
  use Harness.DataCase, async: false

  alias Harness.Ideation
  alias Harness.Ideation.PromoteWorker
  alias Harness.Runs.FakeRunner

  @moduletag :capture_log

  @target_repo "owner/repo"

  setup do
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
    :persistent_term.put({PromoteWorker, :login}, "nyelbangash")

    on_exit(fn ->
      Application.delete_env(:harness, :github_req_options)
      :persistent_term.erase({PromoteWorker, :login})
    end)

    enable_promote!()
    :ok
  end

  # Open the promote gate: policy with our target_repo, no ideation-window restriction,
  # and a low-utilization usage sample so gate(:ideate) passes.
  defp enable_promote! do
    original = Application.fetch_env!(:harness, :policy_path)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "promote-policy-#{System.unique_integer([:positive])}.yaml"
      )

    content =
      File.read!(original)
      |> String.replace(~r/repos: \[\]/, "repos:\n  - #{@target_repo}")
      |> String.replace(~r/ideation_windows:.*/, "ideation_windows: []")

    File.write!(tmp, content)
    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()
    Harness.Usage.record_oauth_sample!(%{seven_day_utilization: 5.0, raw: %{}})

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
    end)
  end

  defp make_session_and_idea do
    {session, root} = Ideation.start_session(%{seed_prompt: "test seed", budget_minutes: 60})
    Harness.Repo.delete_all(Oban.Job)
    idea = Ideation.add_child!(session, root, %{title: "Strong branch", score: 8.5}, "## artifact")
    {session, idea}
  end

  defp canned_contract do
    %{
      "epic" => %{"title" => "Epic: Strong branch", "body" => "This is the epic body."},
      "children" => [
        %{"title" => "Child issue 1", "body" => "Child 1 body with details."},
        %{"title" => "Child issue 2", "body" => "Child 2 body with details."}
      ]
    }
  end

  # Installs a sequenced Req.Test stub. Each element is either a {status, body} tuple
  # or an arity-1 function `fn conn -> conn end`.
  defp sequential_stub(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    Req.Test.stub(__MODULE__, fn conn ->
      handler =
        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> {nil, []}
        end)

      case handler do
        nil ->
          raise "Req.Test sequential stub exhausted at #{conn.method} #{conn.request_path}"

        fun when is_function(fun, 1) ->
          fun.(conn)

        {status, body} ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end
    end)
  end

  defp epic_url(number), do: "https://github.com/#{@target_repo}/issues/#{number}"

  test "happy path: epic + children created with provenance marker and self-assignment" do
    {session, idea} = make_session_and_idea()

    sequential_stub([
      fn conn ->
        # POST epic
        assert conn.method == "POST"
        refute conn.request_path =~ "/comments"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert payload["title"] == "Epic: Strong branch"
        assert payload["assignees"] == ["nyelbangash"]
        assert String.contains?(payload["body"], "harness:v1")

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 100, "html_url" => epic_url(100)})
      end,
      fn conn ->
        # POST child 1
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert payload["title"] == "Child issue 1"
        assert payload["assignees"] == ["nyelbangash"]
        assert String.contains?(payload["body"], "harness:v1")
        assert String.contains?(payload["body"], epic_url(100))

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 101, "html_url" => epic_url(101)})
      end,
      fn conn ->
        # POST child 2
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert payload["title"] == "Child issue 2"

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 102, "html_url" => epic_url(102)})
      end,
      fn conn ->
        # PATCH epic body with task list
        assert conn.method == "PATCH"
        assert conn.request_path =~ "/issues/100"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert String.contains?(payload["body"], "## Child issues")
        assert String.contains?(payload["body"], epic_url(101))
        assert String.contains?(payload["body"], epic_url(102))

        Req.Test.json(conn, %{"number" => 100})
      end
    ])

    FakeRunner.script([
      {:ok, Harness.Fixtures.runner_result(structured_output: canned_contract())}
    ])

    assert :ok =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: @target_repo
             })

    promotion = Ideation.latest_promotion(idea.id)
    assert promotion.status == "succeeded"
    assert promotion.epic_url == epic_url(100)
    assert promotion.epic_number == 100
  end

  test "broadcasts :promotion_completed on session topic after success" do
    {session, idea} = make_session_and_idea()
    Ideation.subscribe(session.id)

    sequential_stub([
      {201, %{"number" => 200, "html_url" => epic_url(200)}},
      {201, %{"number" => 201, "html_url" => epic_url(201)}},
      {201, %{"number" => 202, "html_url" => epic_url(202)}},
      {200, %{"number" => 200}}
    ])

    FakeRunner.script([
      {:ok, Harness.Fixtures.runner_result(structured_output: canned_contract())}
    ])

    assert :ok =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: @target_repo
             })

    assert_receive {:promotion_completed, %{status: "succeeded"}}
  end

  test "policy guard: non-policy repo is cancelled without calling the model" do
    {session, idea} = make_session_and_idea()
    FakeRunner.script([])

    assert {:cancel, :repo_not_in_policy} =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: "not/there"
             })

    assert FakeRunner.executed_specs() == []
  end

  test "policy guard: paused mode is cancelled without calling the model" do
    {session, idea} = make_session_and_idea()
    Harness.Policy.set_mode!(:paused)
    FakeRunner.script([])

    assert {:cancel, :paused} =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: @target_repo
             })

    assert FakeRunner.executed_specs() == []
  end

  test "malformed contract: promotion marked failed, no GitHub issues created" do
    {session, idea} = make_session_and_idea()

    Req.Test.stub(__MODULE__, fn conn ->
      raise "GitHub API should not be called for malformed contract: #{conn.request_path}"
    end)

    FakeRunner.script([
      {:ok, Harness.Fixtures.runner_result(structured_output: %{"garbage" => true})}
    ])

    assert {:cancel, :invalid_contract} =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: @target_repo
             })

    promotion = Ideation.latest_promotion(idea.id)
    assert promotion.status == "failed"
    assert promotion.error_detail == "invalid_contract"
  end

  test "epic creation failure: promotion marked failed, no children attempted" do
    {session, idea} = make_session_and_idea()

    sequential_stub([{422, %{"message" => "Validation Failed"}}])

    FakeRunner.script([
      {:ok, Harness.Fixtures.runner_result(structured_output: canned_contract())}
    ])

    assert {:error, {:epic_creation_failed, {:http_status, 422}}} =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: @target_repo
             })

    promotion = Ideation.latest_promotion(idea.id)
    assert promotion.status == "failed"
    assert promotion.error_detail =~ "epic"
  end

  test "partial child failure: comments on epic, job still succeeds with partial task list" do
    {session, idea} = make_session_and_idea()

    sequential_stub([
      # epic
      {201, %{"number" => 300, "html_url" => epic_url(300)}},
      # child 1 ok
      {201, %{"number" => 301, "html_url" => epic_url(301)}},
      # child 2 fails
      {422, %{"message" => "Validation Failed"}},
      # failure comment on epic
      fn conn ->
        assert conn.method == "POST"
        assert conn.request_path =~ "/issues/300/comments"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert String.contains?(payload["body"], "Child creation stopped")

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 999})
      end,
      # PATCH epic body (partial task list)
      {200, %{"number" => 300}}
    ])

    FakeRunner.script([
      {:ok, Harness.Fixtures.runner_result(structured_output: canned_contract())}
    ])

    assert :ok =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: @target_repo
             })

    promotion = Ideation.latest_promotion(idea.id)
    assert promotion.status == "succeeded"
    assert promotion.epic_number == 300
  end

  test "killed run: promotion marked failed, job cancelled" do
    {session, idea} = make_session_and_idea()

    Req.Test.stub(__MODULE__, fn conn ->
      raise "GitHub API should not be called for killed run: #{conn.request_path}"
    end)

    FakeRunner.script([{:error, :killed}])

    assert {:cancel, :killed} =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: @target_repo
             })

    promotion = Ideation.latest_promotion(idea.id)
    assert promotion.status == "failed"
    assert promotion.error_detail == "killed"
  end

  test "run spec includes seed verbatim and uses :promote kind" do
    {session, idea} = make_session_and_idea()

    sequential_stub([
      {201, %{"number" => 400, "html_url" => epic_url(400)}},
      {201, %{"number" => 401, "html_url" => epic_url(401)}},
      {201, %{"number" => 402, "html_url" => epic_url(402)}},
      {200, %{"number" => 400}}
    ])

    FakeRunner.script([
      fn spec ->
        assert spec.kind == :promote
        assert spec.prompt =~ "test seed"
        assert spec.prompt =~ "Strong branch"
        {:ok, Harness.Fixtures.runner_result(structured_output: canned_contract())}
      end
    ])

    assert :ok =
             perform_job(PromoteWorker, %{
               session_id: session.id,
               idea_id: idea.id,
               target_repo: @target_repo
             })
  end
end
