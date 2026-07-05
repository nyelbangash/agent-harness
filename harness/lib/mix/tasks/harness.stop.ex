defmodule Mix.Tasks.Harness.Stop do
  @shortdoc "Kill running agent sessions and stop the daemon"

  @moduledoc """
  The CLI kill switch. Reads running runs' OS pids straight from the prod
  SQLite database (no BEAM distribution needed), SIGTERMs each claude
  process, then boots the daemon out of launchd (it stays installed; next
  login or `mix harness.install` brings it back).

      mix harness.stop
  """

  use Mix.Task

  @requirements ["app.config"]
  @label "com.nyel.harness"

  @impl Mix.Task
  def run(_args) do
    db = Path.join(Application.fetch_env!(:harness, :harness_home), "harness.db")

    if File.exists?(db) do
      {output, _} =
        System.cmd(
          "sqlite3",
          [db, "select os_pid from runs where status = 'running' and os_pid is not null;"],
          stderr_to_stdout: true
        )

      pids = output |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ ~r/\A\d+\z/))

      for pid <- pids do
        # rows can be stale after an unclean daemon exit and pids get
        # recycled — only signal processes that are actually claude
        case System.cmd("ps", ["-p", pid, "-o", "command="], stderr_to_stdout: true) do
          {command, 0} ->
            if command =~ "claude" do
              System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
              Mix.shell().info("  ✓ SIGTERM run pid #{pid}")
            else
              Mix.shell().info(
                "  · pid #{pid} is no longer a claude process (stale row), skipping"
              )
            end

          _ ->
            Mix.shell().info("  · pid #{pid} already gone")
        end
      end

      if pids == [], do: Mix.shell().info("  · no running agent sessions")
    end

    {uid, 0} = System.cmd("id", ["-u"])
    uid = String.trim(uid)

    case System.cmd("launchctl", ["bootout", "gui/#{uid}/#{@label}"], stderr_to_stdout: true) do
      {_, 0} ->
        Mix.shell().info("  ✓ daemon stopped (still installed; `mix harness.install` restarts)")

      {_, _} ->
        Mix.shell().info("  · daemon was not running under launchd")
    end

    System.cmd("launchctl", ["bootout", "gui/#{uid}/com.nyel.harness.watchdog"],
      stderr_to_stdout: true
    )

    Mix.shell().info("  · watchdog stopped (resumes after next harness.install)")
  end
end
