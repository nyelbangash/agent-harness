# agent-harness

Personal, always-on agentic development system. One Phoenix app (`harness/`) with a Mission Control LiveView dashboard at `http://localhost:4040` (prod) / `:4000` (dev). Four capabilities:

1. **GitHub issue pipeline** — polls issues assigned to you, triages each (auto / plan / skip), and either pre-stages an implementation plan (plan lane) or implements → verifies → opens a PR (auto lane). Never merges, never touches default branches.
2. **Ideation engine** — multi-hour brainstorm → research → craft → critique loop that grows a persistent, compounding idea tree from one seed, ending in a synthesis.
3. **Mission Control** — real-time dashboard: vintage-VDO gauge cluster, issue board, run console with live transcripts, ideation tree, budget panel, mode toggle, and kill switches.
4. **Off-machine lanes** — a GitHub Action lane (`agent-cloud` label) for when the Mac is off, plus notifications (macOS + optional ntfy.sh).

**Start with [`MANUAL.md`](MANUAL.md)** — the user manual (setup, daily operation, every view, troubleshooting). `HANDOFF-agentic-harness.md` is the full spec, `PROGRESS.md` the build journal, `ops/ROUTINES.md` the off-machine lanes.

## Quickstart

```sh
cd harness
mix deps.get
mix ecto.migrate
mix harness.setup      # one-time: prints the Keychain command for your GitHub PAT; also makes ~/.harness
mix harness.doctor     # environment checks — must be all green
mix phx.server         # dev, http://localhost:4000
```

Fill `ops/policy.yaml → github.repos` with the personal repos to watch (each as `"owner/name"`, or `{name: "owner/name", test_command: "mix test"}` — the auto lane needs a test command). The file hot-reloads.

## Always-on operation

```sh
mix harness.install    # launchd LaunchAgent (KeepAlive + caffeinate), prod on 127.0.0.1:4040
mix harness.stop       # kill running agent sessions + stop the daemon
mix harness.uninstall
```

Phone access: `tailscale serve` in front of `:4040` (Tailscale only — never LAN).

## Operating modes (`ops/policy.yaml → mode`, or the rail toggle)

- **plan_only** (default) — triage + plan packets only; no code is written.
- **full_auto** — the auto lane implements and opens PRs, but only inside the `full_auto_windows` and below the utilization thresholds.
- **paused** — drains all model work.

Utilization gates (polled from the Max usage endpoint) tighten the mode automatically; the weekly overflow-$ cap hard-pauses everything.

## Safety invariants (enforced in code)

- Subscription OAuth only — boot **refuses** to start if `ANTHROPIC_API_KEY` is set, and every headless run scrubs it (+ provider-redirect vars) from the child env.
- PR-only git flow; only `harness/*` branches are ever pushed (never a default branch), via `--force-with-lease`.
- Explicit tool whitelists + turn/budget caps + isolation flags on every headless run; issue text is treated as untrusted.
- Kill switches in the UI (per-run + master) and CLI (`mix harness.stop`).
- **Personal repos only** — nothing here ever touches Main Street Health / work repos or credentials.

## Tests

```sh
mix test                    # ~184 tests; DB suites are async: false (SQLite single-writer)
mix test --only real_cli    # hits the real claude CLI (spends subscription tokens) — run deliberately
```
