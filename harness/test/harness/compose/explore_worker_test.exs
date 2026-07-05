defmodule Harness.Compose.ExploreWorkerTest do
  use Harness.DataCase, async: false

  alias Harness.Compose
  alias Harness.Compose.ExploreWorker
  alias Harness.Runs.FakeRunner

  @moduletag :capture_log

  @draft_json Jason.encode!(%{
                "title" => "Speed up widget processing",
                "body" =>
                  "## Problem\n\nWidget is slow.\n\n## Change\n\nOptimize src/widget.ex.\n\n## Acceptance\n\n- Benchmarks pass\n\n## Non-goals\n\nNo UI changes.",
                "scope_hint" => "s",
                "open_questions" => ["Is the bottleneck in parse or render?"]
              })

  setup do
    tmp = Path.join(System.tmp_dir!(), "explore-worker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo_name = "owner/ew#{System.unique_integer([:positive])}"
    create_git_remote!(tmp, repo_name)
    Application.put_env(:harness, :github_remote_base, "file://#{tmp}/")

    on_exit(fn ->
      Application.delete_env(:harness, :github_remote_base)
      File.rm_rf!(tmp)
    end)

    %{repo: repo_name}
  end

  defp writes_draft_json do
    fn spec ->
      File.write!(Path.join(spec.cwd, "DRAFT.json"), @draft_json)
      {:ok, Harness.Fixtures.runner_result()}
    end
  end

  test "happy path: DRAFT.json written → draft updated with title/body, status stays draft",
       ctx do
    draft = draft_fixture(%{repo: ctx.repo})
    FakeRunner.script([writes_draft_json()])

    assert :ok = perform_job(ExploreWorker, %{draft_id: draft.id})

    updated = Compose.get_draft!(draft.id)
    assert updated.status == "draft"
    assert updated.title == "Speed up widget processing"
    assert updated.body =~ "Widget is slow"
    assert updated.scope_hint == "s"
    assert {:ok, ["Is the bottleneck in parse or render?"]} = Jason.decode(updated.open_questions)

    # worktree cleaned up
    assert {:ok, []} = File.ls(Application.fetch_env!(:harness, :workspaces_dir))
  end

  test "missing DRAFT.json → {:error, :missing_draft_artifact}", ctx do
    draft = draft_fixture(%{repo: ctx.repo})
    FakeRunner.script([{:ok, Harness.Fixtures.runner_result()}])

    assert {:error, :missing_draft_artifact} = perform_job(ExploreWorker, %{draft_id: draft.id})
    assert {:ok, []} = File.ls(Application.fetch_env!(:harness, :workspaces_dir))
  end

  test "trivially small DRAFT.json is rejected", ctx do
    draft = draft_fixture(%{repo: ctx.repo})

    FakeRunner.script([
      fn spec ->
        File.write!(Path.join(spec.cwd, "DRAFT.json"), "{}")
        {:ok, Harness.Fixtures.runner_result()}
      end
    ])

    assert {:error, :missing_draft_artifact} = perform_job(ExploreWorker, %{draft_id: draft.id})
  end

  test "gate snooze when policy is paused", ctx do
    draft = draft_fixture(%{repo: ctx.repo})

    original = Application.fetch_env!(:harness, :policy_path)
    tmp = Path.join(System.tmp_dir!(), "paused-policy-#{System.unique_integer([:positive])}.yaml")
    File.write!(tmp, File.read!(original) |> String.replace(~r/^mode: \w+/m, "mode: paused"))
    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
    end)

    assert {:snooze, _} = perform_job(ExploreWorker, %{draft_id: draft.id})
  end

  test "explore run spec uses :explore kind and includes Write in allowed_tools", ctx do
    draft = draft_fixture(%{repo: ctx.repo})
    FakeRunner.script([writes_draft_json()])

    assert :ok = perform_job(ExploreWorker, %{draft_id: draft.id})

    [spec] = FakeRunner.executed_specs()
    assert spec.kind == :explore
    assert "Write" in spec.allowed_tools
    assert spec.output_mode == :stream_json
  end
end
