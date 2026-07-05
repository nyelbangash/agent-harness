defmodule Mix.Tasks.Harness.Uninstall do
  @shortdoc "Remove the launchd LaunchAgent"

  @moduledoc """
  Boots the agent out of launchd and removes the installed plist. The repo
  copy under `ops/` is untouched.

      mix harness.uninstall
  """

  use Mix.Task

  @label "com.nyel.harness"
  @watchdog_label "com.nyel.harness.watchdog"

  @impl Mix.Task
  def run(_args) do
    {uid, 0} = System.cmd("id", ["-u"])
    uid = String.trim(uid)

    case System.cmd("launchctl", ["bootout", "gui/#{uid}/#{@label}"], stderr_to_stdout: true) do
      {_, 0} -> Mix.shell().info("  ✓ booted out gui/#{uid}/#{@label}")
      {_, _} -> Mix.shell().info("  · agent was not loaded")
    end

    plist = Path.expand("~/Library/LaunchAgents/#{@label}.plist")

    if File.exists?(plist) do
      File.rm!(plist)
      Mix.shell().info("  ✓ removed #{plist}")
    end

    System.cmd("launchctl", ["bootout", "gui/#{uid}/#{@watchdog_label}"],
      stderr_to_stdout: true
    )

    watchdog_plist = Path.expand("~/Library/LaunchAgents/#{@watchdog_label}.plist")

    if File.exists?(watchdog_plist) do
      File.rm!(watchdog_plist)
      Mix.shell().info("  ✓ removed #{watchdog_plist}")
    end
  end
end
