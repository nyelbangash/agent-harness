defmodule Harness.Runs.RunServerTest do
  # async: false — swaps the global :claude_executable and shares the sandbox
  # with the RunServer process
  use Harness.DataCase, async: false

  alias Harness.Runs
  alias Harness.Runs.{Runner, RunSpec}

  @moduletag :capture_log

  @fixtures Path.expand("../../support/fixtures/ndjson", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "run-server-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  # a fake "claude": a shell script that ignores its argv and plays a script
  defp stub_executable(tmp, body) do
    path = Path.join(tmp, "claude-stub")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    Application.put_env(:harness, :claude_executable, path)
    on_exit(fn -> Application.delete_env(:harness, :claude_executable) end)
    path
  end

  defp spec(tmp, overrides \\ []) do
    struct!(
      %RunSpec{
        kind: :plan,
        model: "sonnet",
        prompt: "irrelevant to the stub",
        cwd: tmp,
        allowed_tools: ["Read"]
      },
      overrides
    )
  end

  defp execute(spec), do: Runner.ClaudeCLI.execute(spec, [])

  test "happy path: streams events, finalizes from the result envelope", %{tmp: tmp} do
    stub_executable(tmp, ~s(cat "#{@fixtures}/happy_tool_use.ndjson"\n))

    Runs.subscribe()
    assert {:ok, %Runner.Result{} = result} = execute(spec(tmp))

    assert result.subtype == "success"
    assert result.session_id
    assert result.turns > 0
    assert result.cost > 0

    run = Runs.get_run!(result.run_id)
    assert run.status == "succeeded"
    assert run.result_subtype == "success"
    assert run.os_pid
    assert run.exit_code == 0
    assert run.started_at
    assert run.ended_at
    assert run.tokens_out > 0

    assert length(Runs.events(run.id)) == 10
    assert_receive {:run_started, %{id: run_id}}
    assert_receive {:run_updated, %{id: ^run_id, status: "running"}}
    assert_receive {:run_updated, %{id: ^run_id, status: "succeeded"}}
  end

  test "per-event PubSub streams on the run topic", %{tmp: tmp} do
    stub_executable(tmp, ~s(cat "#{@fixtures}/happy_tool_use.ndjson"\n))

    # subscribe to the run topic as soon as the run row exists
    Runs.subscribe()

    task = Task.async(fn -> execute(spec(tmp)) end)
    assert_receive {:run_started, run}, 2_000
    Runs.subscribe(run.id)

    assert {:ok, _} = Task.await(task, 10_000)
    # late subscription may miss early events, but persisted events are complete
    assert length(Runs.events(run.id)) == 10
  end

  test "error_max_turns result → failed run, error tuple with the subtype", %{tmp: tmp} do
    stub_executable(tmp, ~s(cat "#{@fixtures}/error_max_turns.ndjson"\n))

    assert {:error, {:run_failed, "error_max_turns"}} = execute(spec(tmp))

    [run] = Runs.recent_runs(1)
    assert run.status == "failed"
    assert run.result_subtype == "error_max_turns"
    assert run.error =~ "error_max_turns"
  end

  test "json output mode parses the single envelope and structured_output", %{tmp: tmp} do
    envelope =
      Jason.encode!(%{
        type: "result",
        subtype: "success",
        is_error: false,
        num_turns: 2,
        result: "{\"route\":\"plan\"}",
        structured_output: %{route: "plan", confidence: 0.9},
        session_id: "json-mode-session",
        total_cost_usd: 0.02,
        usage: %{input_tokens: 5, output_tokens: 9}
      })

    stub_executable(tmp, "printf '%s' '#{envelope}'\n")

    assert {:ok, result} =
             execute(spec(tmp, output_mode: :json, json_schema: ~s({"type":"object"})))

    assert result.structured_output == %{"route" => "plan", "confidence" => 0.9}
    assert result.session_id == "json-mode-session"

    run = Runs.get_run!(result.run_id)
    assert run.status == "succeeded"
    assert run.tokens_out == 9
  end

  test "kill: SIGTERM ends the run as killed", %{tmp: tmp} do
    stub_executable(tmp, """
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"kill-me","uuid":"x"}'
    sleep 30
    """)

    Runs.subscribe()
    task = Task.async(fn -> execute(spec(tmp)) end)
    assert_receive {:run_updated, %{status: "running"} = run}, 2_000

    assert :ok = Runs.kill(run.id)
    assert {:error, :killed} = Task.await(task, 10_000)

    run = Runs.get_run!(run.id)
    assert run.status == "killed"
    assert run.error =~ "operator"
  end

  test "kill_all sweeps every registered run", %{tmp: tmp} do
    stub_executable(tmp, """
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"s","uuid":"x"}'
    sleep 30
    """)

    Runs.subscribe()
    task = Task.async(fn -> execute(spec(tmp)) end)
    assert_receive {:run_updated, %{status: "running"}}, 2_000

    Runs.kill_all()
    assert {:error, :killed} = Task.await(task, 10_000)
  end

  test "split assistant events with one message id count as one turn", %{tmp: tmp} do
    # two events sharing one message id must be counted as a single turn; a
    # fresh message id would be a second turn.
    same_id_1 =
      ~s({"type":"assistant","message":{"id":"msg_same","role":"assistant","content":[{"type":"text","text":"a"}]},"uuid":"u1"})

    same_id_2 =
      ~s({"type":"assistant","message":{"id":"msg_same","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]},"uuid":"u2"})

    result =
      ~s({"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"ok","session_id":"s","total_cost_usd":0.001,"usage":{"input_tokens":1,"output_tokens":1},"uuid":"u3"})

    stub_executable(tmp, """
    printf '%s\\n' '#{same_id_1}'
    printf '%s\\n' '#{same_id_2}'
    printf '%s\\n' '#{result}'
    """)

    assert {:ok, result} = execute(spec(tmp))
    assert result.subtype == "success"

    [run] = Runs.recent_runs(1)
    assert run.turns == 1
  end

  test "a spawn failure fails the run cleanly", %{tmp: tmp} do
    Application.put_env(:harness, :claude_executable, "definitely-not-a-real-binary-xyz")
    on_exit(fn -> Application.delete_env(:harness, :claude_executable) end)

    assert {:error, {:spawn_failed, _}} = execute(spec(tmp))
    [run] = Runs.recent_runs(1)
    assert run.status == "failed"
  end

  test "wall-clock timeout kills the run", %{tmp: tmp} do
    stub_executable(tmp, """
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"slow","uuid":"x"}'
    sleep 30
    """)

    assert {:error, :timeout} = execute(spec(tmp, timeout_ms: 500))

    [run] = Runs.recent_runs(1)
    assert run.status == "killed"
    assert run.error =~ "timeout"
  end
end
