defmodule Mix.Tasks.Harness.Install do
  @shortdoc "Install the launchd LaunchAgent for always-on operation"

  @moduledoc """
  Prepares prod (secret key, compiled assets), generates the LaunchAgent
  plist (paths resolved from this checkout) into `~/Library/LaunchAgents/`,
  and bootstraps it into the gui launchd domain. The gui domain matters:
  Keychain reads (Claude OAuth, GitHub PAT) only work in a logged-in user
  session. Re-run after moving the repo — the installed plist embeds
  absolute paths.

      mix harness.install
  """

  use Mix.Task

  @requirements ["app.config"]
  @label "com.nyel.harness"
  @watchdog_label "com.nyel.harness.watchdog"

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

    plist_dest = Path.expand("~/Library/LaunchAgents/#{@label}.plist")

    File.mkdir_p!(Path.dirname(plist_dest))
    File.write!(plist_dest, plist_content(home))
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

    install_watchdog(home)
  end

  defp uid do
    {uid, 0} = System.cmd("id", ["-u"])
    String.trim(uid)
  end

  defp install_watchdog(home) do
    project_root = Application.fetch_env!(:harness, :project_root)
    src = Path.join([project_root, "ops", "watchdog.sh"])
    dest = Path.join(home, "watchdog.sh")

    File.cp!(src, dest)
    File.chmod!(dest, 0o755)
    Mix.shell().info("  ✓ #{dest}")

    ntfy_topic = read_ntfy_topic()
    watchdog_plist = Path.expand("~/Library/LaunchAgents/#{@watchdog_label}.plist")
    File.write!(watchdog_plist, watchdog_plist_content(dest, ntfy_topic))
    Mix.shell().info("  ✓ #{watchdog_plist}")

    System.cmd("launchctl", ["bootout", "gui/#{uid()}/#{@watchdog_label}"],
      stderr_to_stdout: true
    )

    case System.cmd("launchctl", ["bootstrap", "gui/#{uid()}", watchdog_plist],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Mix.shell().info("  ✓ bootstrapped gui/#{uid()}/#{@watchdog_label}")

      {output, code} ->
        Mix.raise("launchctl bootstrap (watchdog) exited #{code}: #{String.trim(output)}")
    end
  end

  defp read_ntfy_topic do
    path = Application.fetch_env!(:harness, :policy_path)

    case YamlElixir.read_from_file(path) do
      {:ok, %{"notify" => %{"ntfy_topic" => topic}}} when is_binary(topic) and topic != "" ->
        topic

      _ ->
        nil
    end
  end

  defp watchdog_plist_content(script_path, ntfy_topic) do
    env_block =
      if ntfy_topic do
        "\n    <key>NTFY_TOPIC</key><string>#{ntfy_topic}</string>"
      else
        ""
      end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>#{@watchdog_label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>/bin/sh</string><string>#{script_path}</string>
      </array>
      <key>StartInterval</key><integer>300</integer>
      <key>RunAtLoad</key><true/>
      <key>EnvironmentVariables</key>
      <dict>#{env_block}
      </dict>
    </dict></plist>
    """
  end

  defp plist_content(home) do
    app_dir = Path.join(Application.fetch_env!(:harness, :project_root), "harness")

    # launchd login shells don't read .zshrc, so user-dir installs of the
    # claude CLI (~/.local/bin) vanish from PATH and BootCheck fails closed.
    # Bake the installing shell's PATH in — re-run install if it changes.
    path = System.get_env("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>#{@label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>/bin/zsh</string><string>-lc</string>
        <string>caffeinate -is mix phx.server</string>
      </array>
      <key>WorkingDirectory</key><string>#{app_dir}</string>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>StandardOutPath</key><string>#{home}/logs/harness.out.log</string>
      <key>StandardErrorPath</key><string>#{home}/logs/harness.err.log</string>
      <key>EnvironmentVariables</key>
      <dict>
        <key>MIX_ENV</key><string>prod</string>
        <key>PATH</key><string>#{path}</string>
      </dict>
    </dict></plist>
    """
  end
end
