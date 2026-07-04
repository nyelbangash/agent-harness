# :real_cli tests hit the actual claude CLI (subscription tokens) — run them
# deliberately with: mix test --only real_cli
ExUnit.start(exclude: [:real_cli])
Ecto.Adapters.SQL.Sandbox.mode(Harness.Repo, :manual)

# a crashed prior run can leave worktrees behind; start every suite clean
workspaces = Application.fetch_env!(:harness, :workspaces_dir)
File.rm_rf!(workspaces)
File.mkdir_p!(workspaces)
