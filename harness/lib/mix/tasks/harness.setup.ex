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

    # Deliberately NOT prompting from inside Mix: without a real controlling
    # TTY, `security -w` cannot disable echo and the pasted token appears in
    # plaintext in the terminal. The user runs the command in their own shell.
    Mix.shell().info("""

    Next: store the GitHub fine-grained PAT in the Keychain (service #{service}).
    Create one at https://github.com/settings/personal-access-tokens with:
      Repository access: only the repos in ops/policy.yaml
      Permissions: Contents RW · Issues RW · Pull requests RW (Metadata R is automatic)

    Then run this yourself, directly in your terminal (it prompts twice with
    hidden input — if you can SEE the token as you paste, abort and revoke it):

      security add-generic-password -U -s "#{service}" -a "$USER" -T /usr/bin/security -w

    Verify afterwards with: mix harness.doctor
    """)

    Harness.Secrets.forget_github_pat()
  end
end
