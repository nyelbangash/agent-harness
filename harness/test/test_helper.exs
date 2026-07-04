# :real_cli tests hit the actual claude CLI (subscription tokens) — run them
# deliberately with: mix test --only real_cli
ExUnit.start(exclude: [:real_cli])
Ecto.Adapters.SQL.Sandbox.mode(Harness.Repo, :manual)
