defmodule Mix.Tasks.Harness.Setup do
  @shortdoc "One-time setup: ~/.harness directories + GitHub PAT into Keychain"

  @moduledoc """
  Creates the `~/.harness` directory tree and stores the fine-grained GitHub
  PAT in the macOS login Keychain (service `com.nyel.harness.github`).

  `security` prompts for the token on the terminal so it never appears in
  shell history or `ps` output. Re-run any time to rotate the PAT.

      mix harness.setup
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    home = Application.fetch_env!(:harness, :harness_home)

    for dir <- ["repos", "plans", "logs", "ideation"] do
      path = Path.join(home, dir)
      File.mkdir_p!(path)
      Mix.shell().info("  ✓ #{path}")
    end

    service = Harness.Secrets.pat_service()
    user = System.get_env("USER")

    Mix.shell().info("""

    Storing the GitHub fine-grained PAT in the Keychain (service #{service}).
    Create one at https://github.com/settings/personal-access-tokens with:
      Repository access: only the repos in ops/policy.yaml
      Permissions: Contents RW · Issues RW · Pull requests RW (Metadata R is automatic)

    security will now prompt for the token (input is hidden):
    """)

    status =
      Mix.shell().cmd(
        ~s(security add-generic-password -U -s "#{service}" -a "#{user}" -T /usr/bin/security -w)
      )

    if status == 0 do
      Harness.Secrets.forget_github_pat()
      Mix.shell().info("  ✓ PAT stored. Run `mix harness.doctor` to verify against the GitHub API.")
    else
      Mix.raise("security add-generic-password exited #{status}")
    end
  end
end
