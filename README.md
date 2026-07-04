# agent-harness

Personal always-on agentic development system. One Phoenix app (`harness/`) that:

1. polls GitHub issues assigned to Nyel, triages them (auto / plan / skip), and pre-stages implementation plans (auto lane lands in Phase 2);
2. will run multi-hour ideation sessions growing a persistent idea tree (Phase 3);
3. serves **Mission Control**, a local LiveView dashboard at `http://localhost:4040` (prod) / `:4000` (dev).

Read `HANDOFF-agentic-harness.md` for the full spec and `PROGRESS.md` for where things stand.

## Quickstart

```sh
cd harness
mix deps.get
mix ecto.migrate
mix harness.setup      # one-time: GitHub PAT into Keychain, ~/.harness dirs
mix harness.doctor     # environment checks — must be all green
mix phx.server         # dev, http://localhost:4000
```

Always-on operation:

```sh
mix harness.install    # launchd LaunchAgent (KeepAlive + caffeinate), prod on :4040
mix harness.stop       # kill running agent sessions + stop the daemon
mix harness.uninstall
```

Configuration lives in `ops/policy.yaml` (hot-reloaded). Prompts in `ops/prompts/`.

Safety invariants: subscription OAuth only (boot refuses if `ANTHROPIC_API_KEY` is set), PR-only git flow, explicit tool whitelists on every headless run, kill switches in the UI and CLI, personal repos only.
