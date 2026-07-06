defmodule Mix.Tasks.Harness.Setup do
  @shortdoc "One-time setup: ~/.harness directories + GitHub PAT into Keychain"

  @moduledoc """
  Creates the `~/.harness` directory tree and stores a fine-grained GitHub
  PAT in the macOS login Keychain (service `com.nyel.harness.github`).

  `security` prompts for the token on the terminal so it never appears in
  shell history or `ps` output. Re-run any time to rotate the PAT.

      mix harness.setup

  Fine-grained PATs bind to a single resource owner. To store a PAT for an
  org or collaborator repo's owner (service `com.nyel.harness.github.<owner>`,
  falls back to the default service when unset), pass the owner:

      mix harness.setup my-org
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    home = Application.fetch_env!(:harness, :harness_home)

    for dir <- ["repos", "plans", "logs", "ideation"] do
      path = Path.join(home, dir)
      File.mkdir_p!(path)
      Mix.shell().info("  ✓ #{path}")
    end

    case args do
      [] -> setup_service(Harness.Secrets.pat_service(), nil)
      [owner] -> setup_service(Harness.Secrets.pat_service(owner), owner)
    end
  end

  defp setup_service(service, owner) do
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

    if owner,
      do: Harness.Secrets.forget_github_pat(owner),
      else: Harness.Secrets.forget_github_pat()
  end
end
