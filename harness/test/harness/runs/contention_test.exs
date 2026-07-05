defmodule Harness.Runs.ContentionTest do
  # async: false — swaps the global :claude_executable and shares the sandbox
  # with the RunServer process (same pattern as run_server_test.exs)
  use Harness.DataCase, async: false

  alias Harness.Runs
  alias Harness.Runs.{Runner, RunSpec}

  @moduletag :capture_log

  @fixtures Path.expand("../../support/fixtures/ndjson", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "contention-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp stub_executable(tmp, body) do
    path = Path.join(tmp, "claude-stub")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    Application.put_env(:harness, :claude_executable, path)
    on_exit(fn -> Application.delete_env(:harness, :claude_executable) end)
    path
  end

  defp spec(tmp) do
    %RunSpec{
      kind: :plan,
      model: "sonnet",
      prompt: "contention test",
      cwd: tmp,
      allowed_tools: [],
      max_turns: 10
    }
  end

  test "two concurrent runs with concurrent DB writer: no crash, all events persisted", %{
    tmp: tmp
  } do
    stub_executable(tmp, ~s(cat "#{@fixtures}/happy_tool_use.ndjson"\n))

    # Simulates Oban / PollWorker write pressure: 30 inserts at ~5 ms intervals
    # while both run sessions are actively streaming events.
    writer =
      Task.async(fn ->
        for _ <- 1..30 do
          Runs.create_run!(%{kind: "plan", status: "running", model: "sonnet"})
          Process.sleep(5)
        end
      end)

    t1 = Task.async(fn -> Runner.ClaudeCLI.execute(spec(tmp), []) end)
    t2 = Task.async(fn -> Runner.ClaudeCLI.execute(spec(tmp), []) end)

    Task.await(writer, 5_000)
    assert {:ok, %Runner.Result{run_id: id1}} = Task.await(t1, 15_000)
    assert {:ok, %Runner.Result{run_id: id2}} = Task.await(t2, 15_000)
    assert id1 != id2

    # Regression: run 8's failure mode (runner crashed: Exqlite.Error Database busy)
    # cannot recur — all 10 events per run must be persisted.
    assert length(Runs.events(id1)) == 10
    assert length(Runs.events(id2)) == 10
  end
end
