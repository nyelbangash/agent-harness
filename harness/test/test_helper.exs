# :real_cli tests hit the actual claude CLI (subscription tokens) — run them
# deliberately with: mix test --only real_cli
ExUnit.start(exclude: [:real_cli])
Ecto.Adapters.SQL.Sandbox.mode(Harness.Repo, :manual)

# a crashed prior run can leave worktrees behind; start every suite clean
workspaces = Application.fetch_env!(:harness, :workspaces_dir)
File.rm_rf!(workspaces)
File.mkdir_p!(workspaces)

# base clones (plus plan/ideation artifacts) outlive the per-test file://
# remotes they track, and unique_integer repo names repeat across BEAM boots,
# so a later run can adopt a stale clone whose remote is gone
File.rm_rf!(Application.fetch_env!(:harness, :harness_home))
