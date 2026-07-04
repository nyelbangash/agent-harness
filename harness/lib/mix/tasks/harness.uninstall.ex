defmodule Mix.Tasks.Harness.Uninstall do
  @shortdoc "Remove the launchd LaunchAgent"

  @moduledoc """
  Boots the agent out of launchd and removes the installed plist. The repo
  copy under `ops/` is untouched.

      mix harness.uninstall
  """

  use Mix.Task

  @label "com.nyel.harness"

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
  end
end
