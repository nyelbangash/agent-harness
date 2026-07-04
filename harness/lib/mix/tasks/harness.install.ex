defmodule Mix.Tasks.Harness.Install do
  @shortdoc "Install the launchd LaunchAgent for always-on operation"

  @moduledoc """
  Prepares prod (secret key, compiled assets), copies
  `ops/com.nyel.harness.plist` into `~/Library/LaunchAgents/`, and bootstraps
  it into the gui launchd domain. The gui domain matters: Keychain reads
  (Claude OAuth, GitHub PAT) only work in a logged-in user session.

      mix harness.install
  """

  use Mix.Task

  @requirements ["app.config"]
  @label "com.nyel.harness"

  @impl Mix.Task
  def run(_args) do
    home = Application.fetch_env!(:harness, :harness_home)
    File.mkdir_p!(Path.join(home, "logs"))

    secret_path = Path.join(home, "secret_key_base")

    unless File.exists?(secret_path) do
      secret = :crypto.strong_rand_bytes(48) |> Base.encode64()
      File.write!(secret_path, secret)
      File.chmod!(secret_path, 0o600)
      Mix.shell().info("  ✓ generated #{secret_path}")
    end

    Mix.shell().info("  … building prod assets (MIX_ENV=prod compile + assets.deploy)")

    if Mix.shell().cmd("MIX_ENV=prod mix do compile + assets.deploy") != 0 do
      Mix.raise("prod build failed")
    end

    plist_source =
      Path.join(Application.fetch_env!(:harness, :project_root), "ops/#{@label}.plist")

    plist_dest = Path.expand("~/Library/LaunchAgents/#{@label}.plist")

    File.mkdir_p!(Path.dirname(plist_dest))
    File.cp!(plist_source, plist_dest)
    Mix.shell().info("  ✓ #{plist_dest}")

    # Re-bootstrap if already loaded
    System.cmd("launchctl", ["bootout", "gui/#{uid()}/#{@label}"], stderr_to_stdout: true)

    case System.cmd("launchctl", ["bootstrap", "gui/#{uid()}", plist_dest],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Mix.shell().info("""
          ✓ bootstrapped gui/#{uid()}/#{@label}

        Mission Control: http://localhost:4040
        Logs: #{home}/logs/harness.{out,err}.log
        Status: launchctl print gui/#{uid()}/#{@label}
        """)

      {output, code} ->
        Mix.raise("launchctl bootstrap exited #{code}: #{String.trim(output)}")
    end
  end

  defp uid do
    {uid, 0} = System.cmd("id", ["-u"])
    String.trim(uid)
  end
end
