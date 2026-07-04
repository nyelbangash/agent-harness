# Harness — Progress Journal

(reverse chronological; one entry per working session)

## 2026-07-04 · session 1 · Phase 0 COMPLETE (launchd install awaits Nyel)

**Gate results:** `mix harness.doctor` all green (PAT + launchd rows are warns by design — see below). `ANTHROPIC_API_KEY=… mix run` refuses to boot with exit 1. Policy hot-reload verified against a live dev server. Prod compile + assets.deploy + boot verified serving HTTP 200 on 127.0.0.1:4040. 30 tests green.

**Awaiting Nyel (two interactive steps):**
1. `mix harness.setup` — prompts for the fine-grained GitHub PAT (Contents RW, Issues RW, Pull requests RW, scoped to policy repos) and stores it in the Keychain.
2. `mix harness.install` — bootstraps the launchd LaunchAgent (permission classifier correctly refused to let the agent self-install a persistent daemon).

**Known nit:** transient `Exqlite database is locked` errors at boot while the pool races the auto-migrator; connections retry and recover. Cosmetic; revisit if it ever crash-loops under launchd KeepAlive.

## 2026-07-04 · session 1 · Phase 0 (planning notes)

**Done:** Plan approved (see `~/.claude/plans/sunny-tickling-forest.md` for the full Phase 0+1 plan). Repo initialized at `~/Documents/ProjectEx` (Nyel's call: ProjectEx *is* the repo; spec's `/Users/nyel/agent-harness` paths corrected throughout). Spec committed verbatim as HANDOFF-agentic-harness.md.

**Verified before building** (probed CLI 2.1.195 + adversarially fact-checked live docs):
- `--json-schema` gives CLI-validated `structured_output` — used for triage. `--max-turns` works (hidden from --help).
- `claude auth status --json` is the subscription boot assertion (spec's `claude /status` isn't a headless surface).
- stream-json requires `--verbose`; emits `rate_limit_event` (free five-hour usage signal) + `result.subtype` (branch on subtype, never is_error).
- Oban 2.23 Lite engine on SQLite: Cron/unique work single-node; must set `default_transaction_mode: :immediate`; no async DB tests; never two app instances on one DB file.
- GitHub: per-repo assignee query + free authorized 304s (ETags); push via ephemeral credential helper; PAT + app must live in the gui launchd domain (Keychain).
- Usage endpoint is undocumented; UA `claude-code/<ver>` required; fail closed to plan_only on staleness.

**Decisions:** policy.yaml = spec §7 exactly + 4 flagged additions (plan.post_to_issue, triage/plan max_turns, low_confidence_floor 0.4); `dontAsk` permission mode instead of acceptEdits (deny-by-default headless); PlanWorker rides :implement queue (no :plan queue in spec's fixed set); model-proposed `skip` demotes to plan (spec-literal); host does all git commits/pushes, agents only write files.

**Next:** Phase 0 chunks 0.1–0.4, then `mix harness.doctor` gate.

**Blockers:** none.

**Gate status:** Phase 0 ▢ · Phase 1 ▢ · Phase 2 ▢ · Phase 3 ▢ · Phase 4 ▢
