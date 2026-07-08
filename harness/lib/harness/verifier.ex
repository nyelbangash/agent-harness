defmodule Harness.Verifier do
  @moduledoc """
  The hard verification gate (spec §4.3.3) — runs the repo's configured
  test/lint/typecheck commands IN ELIXIR against the worktree. The agent's
  claim that tests pass is never trusted; this is the arbiter.

  Commands come from the operator's policy.yaml (trusted config, run through
  the shell deliberately so entries like `mix test --color` work).
  """

  @command_timeout :timer.minutes(15)

  @type outcome :: :ok | {:failed, String.t()}

  @doc "Run every configured command in order; stop at the first failure."
  @spec verify(Path.t(), Harness.Policy.Schema.Repo.t(), keyword()) :: outcome()
  def verify(worktree, repo_cfg, opts \\ []) do
    on_output = Keyword.get(opts, :on_output)

    commands =
      [
        {"test", repo_cfg.test_command},
        {"lint", repo_cfg.lint_command},
        {"typecheck", repo_cfg.typecheck_command},
        {"ui", repo_cfg.playwright_command}
      ]
      |> Enum.reject(fn {_label, cmd} -> is_nil(cmd) or cmd == "" end)

    Enum.reduce_while(commands, :ok, fn {label, command}, :ok ->
      case run(worktree, command, on_output) do
        {_output, 0} ->
          {:cont, :ok}

        {output, code} ->
          transcript = """
          #{label} command failed (exit #{code}): #{command}

          #{tail(output, 6_000)}
          """

          {:halt, {:failed, transcript}}
      end
    end)
  end

  defp run(worktree, command, on_output) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        # `exec 0</dev/null;` detaches stdin WITHOUT wrapping the command in
        # exec — `exec cmd1 && cmd2` would silently drop cmd2
        args: ["-c", "exec 0</dev/null; #{command}"],
        cd: worktree,
        env: Harness.Runs.CLIArgs.env()
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    collect(port, os_pid, on_output, "", System.monotonic_time(:millisecond) + @command_timeout)
  end

  defp collect(port, os_pid, on_output, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        if on_output, do: on_output.(chunk)
        collect(port, os_pid, on_output, acc <> chunk, deadline)

      {^port, {:exit_status, code}} ->
        {acc, code}
    after
      remaining ->
        if is_integer(os_pid) do
          System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
          Process.sleep(2_000)
          System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        end

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          3_000 -> Port.close(port)
        end

        {acc <> "\n(verification command timed out)", 124}
    end
  end

  defp tail(output, limit) do
    if String.length(output) > limit do
      "… (truncated)\n" <> String.slice(output, -limit, limit)
    else
      output
    end
  end
end
