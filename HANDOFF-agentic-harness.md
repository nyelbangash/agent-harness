# HANDOFF SPEC — Personal Agentic Harness + Mission Control Dashboard

Owner: Nyel Bangash · macOS · Claude Max 20x
Implementing agent: read this entire document before writing any code. Start in plan mode, present your plan against the phase gates in §10, and get explicit approval before Phase 0 scaffolding.

## 1. Mission

Build a locally-run, always-on agentic development system with three capabilities:

1. **GitHub issue pipeline.** Continuously ingest issues assigned to Nyel. Triage each into `auto` (implement → branch → push → PR) or `plan` (research the codebase, assemble full context, and write an implementation plan so the work is pre-staged for a human).
2. **Ideation engine.** Given one broad product/feature thought, run for multiple hours in a brainstorm → research → craft → critique loop, growing a persistent tree of ideas that compounds across iterations without drifting.
3. **Mission Control.** A polished, real-time local web dashboard — the single pane of glass for everything above: pipeline state, live agent runs, ideation trees, usage/budget gauges, kill switches, and policy configuration.

Non-goals: multi-user support, cloud deployment, anything touching Main Street Health repos or credentials. Personal repos only.

## 2. Stack decision (already made — do not relitigate)

- Core app: Elixir / Phoenix (Nyel's home turf). One application, name `harness`.
  - Oban — job queue + cron. Every unit of work (poll, triage, implement, ideate-iteration) is an Oban job. Use queues: `:triage`, `:implement`, `:ideate`, `:ops` with per-queue concurrency limits.
  - Phoenix LiveView — Mission Control UI. Real-time via PubSub; every state change in the system broadcasts.
  - SQLite via `ecto_sqlite3` — zero-ops single-user store. DB file lives at `~/.harness/harness.db`.
- Agent execution: shell out to headless Claude Code from Oban workers.
  - Phase 1–2: `claude -p` with `--output-format stream-json`, consumed through an Elixir Port line-by-line (NDJSON events → persist to `run_events`, broadcast to LiveView).
  - Phase 3: add a thin TypeScript sidecar on `@anthropic-ai/claude-agent-sdk` (invoked the same way, NDJSON on stdout) when we need hooks (PreToolUse gates), subagents, and structured outputs. The Elixir side must not care which runner produced the event stream — define one event schema (§6).
- GitHub: REST via a fine-grained PAT (see §9) using `Req`. Phase 1 uses polling (2-minute Oban cron). Webhooks are a later optimization, not a requirement.
- Auth to Claude: Max 20x subscription via `claude login` (OAuth). Never set `ANTHROPIC_API_KEY` in any environment the daemon inherits — it silently switches billing to API pay-as-you-go. Add a boot-time assertion that refuses to start if that env var is present.

## 3. Repository layout

```
agent-harness/
├── HANDOFF-agentic-harness.md      # this file
├── harness/                        # Phoenix app
│   ├── lib/harness/
│   │   ├── github/                 # client, poller, triage, PR builder
│   │   ├── runs/                   # run lifecycle, port supervisor, event ingest
│   │   ├── ideation/               # tree engine, iteration workers
│   │   ├── policy/                 # policy.yaml loader, budget/utilization gates
│   │   └── usage/                  # usage poller, gauges, overflow accounting
│   ├── lib/harness_web/            # LiveView: Mission Control
│   └── priv/repo/migrations/
├── runner/                         # Phase 3 TS sidecar (Agent SDK)
├── ops/
│   ├── policy.yaml                 # single source of truth for behavior (§7)
│   ├── com.nyel.harness.plist      # launchd daemon (§8)
│   └── prompts/                    # versioned prompt templates per worker type
└── workspaces/                     # git worktrees created per run (gitignored)
```

## 4. GitHub issue pipeline

### 4.1 Ingest

Oban cron (`*/2 * * * *`): fetch open issues assigned to Nyel across the repos listed in `policy.yaml → github.repos`. Upsert into `issues` table keyed by `{repo, number}`. New or `updated_at`-changed issues enqueue a `TriageWorker`.

### 4.2 Triage (Sonnet, cheap and structured)

`TriageWorker` runs a short headless session with the issue body, comments, labels, and a shallow repo map. It must return strict JSON (schema-validate; retry once on parse failure):

```json
{
  "route": "auto | plan | skip",
  "confidence": 0.0,
  "reasoning": "...",
  "estimated_scope": "xs | s | m | l",
  "risk_flags": ["touches_auth", "schema_migration", "..."]
}
```

Routing rules (encode in Elixir, not in the prompt — the model proposes, the policy disposes):

- `auto` requires: confidence ≥ `policy.triage.auto_threshold` (default 0.75), scope ∈ {xs, s}, zero risk flags, repo has a passing test command configured, and current mode is `full_auto`.
- Anything else → `plan`. Issues labeled `human-only` → `skip`. Ambiguous triage (confidence < 0.4) escalates to one Opus re-triage before defaulting to `plan`.

### 4.3 Auto lane

`ImplementWorker`, one per issue, each in its own git worktree under `workspaces/`:

1. Create branch `harness/issue-{number}-{slug}` from default branch.
2. Run headless Claude Code with the issue context + repo `CLAUDE.md`, `--max-turns` from policy, allowed-tools whitelist (§9).
3. Verification gate (hard, in Elixir): run the repo's configured test + lint + typecheck commands. Failures loop back to the agent up to `policy.implement.max_fix_cycles` (default 2); still failing → demote the issue to `plan` lane with the failure transcript attached.
4. Push branch, open PR with a structured body (summary, approach, test evidence, transcript link into Mission Control). Comment on the issue linking the PR.
5. The agent never merges. The agent never touches the default branch.

### 4.4 Plan lane

`PlanWorker` produces a context packet committed to a `harness/plans/issue-{number}` branch (or posted as an issue comment if `policy.plan.post_to_issue`):

- `PLAN.md` — problem restatement, proposed implementation plan with file-level specifics, alternatives considered, open questions for Nyel.
- `CONTEXT.md` — relevant files with line references, related PRs/issues, prior art found in the codebase, external docs consulted.

Plan packets appear in Mission Control's "Ready for review" column with a one-click "promote to auto" action (which enqueues an `ImplementWorker` seeded with the plan).

## 5. Ideation engine

### 5.1 Data model — the idea tree

```
ideas: id, session_id, parent_id, depth, title, status(seed|expanded|pruned|synthesized),
       score(0-10), artifact_path, model_used, tokens_in, tokens_out, inserted_at
ideation_sessions: id, seed_prompt, mode, budget_minutes, status, started_at, ended_at
```

Artifacts are markdown files under `~/.harness/ideation/{session}/{node}.md` — the DB holds structure and metadata, files hold the thinking. This survives restarts and lets sessions resume mid-tree.

### 5.2 The loop (Ralph-style: fresh context every iteration, state on disk)

Each iteration is one Oban job = one fresh headless session. No conversation carryover — the tree is the memory. An iteration:

1. Select the frontier node: highest `score × novelty_decay(depth)` among unexpanded nodes (policy-tunable). This is what makes the tree compound instead of tunnel.
2. Load a compiled context: seed prompt + the selected node's ancestor chain + sibling summaries (one line each) + the session's running `JOURNAL.md`.
3. Work (Sonnet): branch 2–4 child ideas OR deepen the node with research (web search allowed) and a crafted artifact — the prompt template alternates diverge and develop modes by depth parity.
4. Persist children + artifact + a 3-line journal entry ("what I tried, what surprised me, what's next").
5. Critique checkpoint (Opus, every `policy.ideate.critique_every` = 5 iterations): score the frontier, prune dead branches (mark, never delete), flag drift from the seed intent, and write a synthesis note.
6. Stop when: budget minutes exhausted, utilization gate trips (§7), frontier is empty, or two consecutive critiques report no material progress. On stop, a final Opus synthesis writes `SYNTHESIS.md`: the 3–5 strongest branches, why, and recommended next actions.

Anti-drift rules: the seed prompt is included verbatim every iteration; critique explicitly answers "is this still in service of the seed?"; journal entries are capped at 3 lines to prevent the journal itself from becoming context bloat.

## 6. Run infrastructure (shared by both engines)

- `runs`: id, kind(triage|implement|plan|ideate|critique), ref (issue id / idea id), model, status(queued|running|verifying|succeeded|failed|killed), turns, tokens_in/out, cost_estimate, worktree, started/ended.
- `run_events`: run_id, seq, type(text|tool_use|tool_result|error|system), payload(json), at. Every NDJSON line from the runner lands here and broadcasts on `runs:{id}`.
- A `RunSupervisor` (DynamicSupervisor) owns each Port; killing a run = closing the Port + marking status `killed` + cleaning the worktree. The dashboard kill button and `mix harness.stop` both route here.
- Boot assertions: `claude --version` works, `claude` is subscription-authed (parse `claude /status` output), `gh`/PAT valid, `ANTHROPIC_API_KEY` unset, worktree dir writable.

## 7. Policy — `ops/policy.yaml` (create exactly this as the default)

```yaml
mode: plan_only          # plan_only | full_auto | paused — flippable from Mission Control
models:
  triage: sonnet
  implement: sonnet
  plan: sonnet
  ideate: sonnet
  critique: opus
  escalation: opus
schedule:
  full_auto_windows: ["20:00-06:00"]     # local time; outside these, auto lane demotes to plan
  ideation_windows: ["21:00-02:00"]
  max_ideation_sessions_per_week: 3
budgets:
  opus_hours_weekly_cap: 18
  overflow_usd_weekly_cap: 25            # hard stop on API-rate overflow spend
  implement_max_turns: 60
  ideate_iteration_max_turns: 25
utilization_gates:                        # polled from https://claude.ai/api/oauth/usage
  poll_minutes: 10
  full_auto_below: 0.60                   # weekly (seven_day) utilization thresholds
  defer_ideation_above: 0.60
  plan_only_above: 0.80
  pause_above: 0.90
triage:
  auto_threshold: 0.75
implement:
  max_fix_cycles: 2
ideate:
  critique_every: 5
  default_budget_minutes: 180
github:
  repos: []                               # Nyel fills in
  poll_minutes: 2
billing_model: subscription_pool          # subscription_pool | sdk_credit — see §11
calendar_notes:
  - "2026-07-13: temporary +50% weekly limit expires; expect thresholds to bite sooner"
```

The `Policy` module hot-reloads this file (fs watcher) and exposes `Policy.gate?/1` checks that every worker calls before starting model work. The utilization poller stores samples in `usage_samples` and computes the gates; treat the endpoint as undocumented — on repeated failure, fail closed to `plan_only` and surface a warning banner in Mission Control.

## 8. Always-on macOS operation

`ops/com.nyel.harness.plist` (installed to `~/Library/LaunchAgents/`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.nyel.harness</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string><string>-lc</string>
    <string>caffeinate -is mix phx.server</string>
  </array>
  <key>WorkingDirectory</key><string>/Users/nyel/agent-harness/harness</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/nyel/.harness/logs/harness.out.log</string>
  <key>StandardErrorPath</key><string>/Users/nyel/.harness/logs/harness.err.log</string>
  <key>EnvironmentVariables</key>
  <dict><key>MIX_ENV</key><string>prod</string></dict>
</dict></plist>
```

Notes for the agent: `caffeinate -is` prevents idle/system sleep while the daemon lives; verify the login shell doesn't export `ANTHROPIC_API_KEY`. Provide `mix harness.install` / `harness.uninstall` tasks that manage `launchctl bootstrap/bootout`.

Off-machine lanes (Phase 4, keep thin): (a) the `claude-code-action` GitHub Actions workflow authenticated with `CLAUDE_CODE_OAUTH_TOKEN`, triggered by an `agent-cloud` label, as the lane for when the Mac is off; (b) Claude Code Routines for scheduled recurring tasks and Claude Code on the web for sessions Nyel wants to teleport between cloud and local. Mission Control should display work arriving from these lanes (they converge on GitHub PRs/branches anyway) but does not orchestrate them.

## 9. Safety guardrails (non-negotiable, enforced in code)

1. Fine-grained PAT scoped to only the repos in policy: Contents RW, Pull requests RW, Issues RW, Metadata R. Nothing org-wide. Stored in macOS Keychain, read at boot via `security find-generic-password`; never in the repo, never in the plist.
2. PR-only workflow. No pushes to default branches — enforce with a pre-push check in the worker and branch protection on the repos.
3. Headless invocations always use an explicit allowed-tools whitelist (`Read, Edit, Write, Bash(git *), Bash(mix *), Bash(npm *), Grep, Glob, WebSearch` — tune per repo) and `--max-turns`. Never `--dangerously-skip-permissions` outside the worktree sandbox; prefer `--permission-mode acceptEdits` scoped to the worktree.
4. Every run has a kill switch (UI + CLI). `mode: paused` drains queues gracefully.
5. Overflow spend accounting: estimate cost per run from token counts; when weekly overflow estimate ≥ cap, hard-pause and notify.
6. Notifications: macOS `osascript` notification + optional ntfy.sh topic for: PR opened, plan ready, run failed, gates tripped, budget ≥ 80%.
7. Nothing in this system ever configures credentials for, clones, or reads MSH/work repositories.

## 10. Phased build plan and acceptance gates

Phase 0 — Scaffold (half day). Repo layout, Phoenix app, SQLite, policy loader, boot assertions, launchd tasks. Gate: `mix harness.doctor` passes all environment checks.

Phase 1 — Plan-only pipeline + minimal Mission Control (1–2 days). Poller → triage → plan packets. Dashboard: Overview + Issue board (read-only). Gate: a real issue assigned to Nyel produces a reviewed-quality PLAN.md + CONTEXT.md within 15 minutes, visible live in the UI.

Phase 2 — Auto lane + run console (2–3 days). Worktrees, implement worker, verification gates, PR creation, Runs view with live transcript + kill switch, mode toggle. Gate: an `xs` labeled test issue goes issue → green PR with zero human input, and a deliberately failing test demotes cleanly to plan lane.

Phase 3 — Ideation engine + tree UI (2–3 days). Session CRUD, iteration/critique workers, tree visualization, synthesis. TS sidecar if hooks are needed. Gate: a 3-hour seeded session produces a ≥25-node tree with prunes, journal, and a synthesis Nyel judges genuinely useful.

Phase 4 — Off-machine lanes + notifications (1 day). GitHub Action workflow, Routines doc, ntfy/macOS alerts, budget panel wired to real overflow accounting.

Work one phase per session where possible; keep a `PROGRESS.md` journal at repo root (what's done, what's next, decisions made) so any fresh agent session can resume cold.

## 11. Billing awareness (encode, don't hardcode)

`billing_model: subscription_pool` reflects today's reality: headless/Agent SDK usage draws from the Max subscription after Anthropic paused its June 15 separate-credit change. When Anthropic ships the revised split, flip to `sdk_credit`, which changes budget math: gates track the monthly SDK credit balance + overflow cap instead of seven-day utilization. Structure the `Usage` module so both strategies implement one behaviour.

## 12. Mission Control — design brief

Subject: a private instrument panel for one engineer's fleet of autonomous agents. Audience of exactly one. The page's job: answer "what is the system doing, is it healthy, and what needs me?" in under five seconds.

Signature element — the instrument cluster. Nyel restores a 1971 Mercedes W114; the dashboard's one memorable move is rendering the four critical meters (5-hour session, weekly utilization, Opus hours, overflow $) as a row of round analog gauges in the spirit of a vintage VDO cluster: thin needle, fine tick marks, a small red zone at the gate thresholds, odometer-style tabular numerals beneath. Everything else on the page stays quiet and disciplined so the cluster carries the identity. No skeuomorphic chrome or leather textures — the reference is the geometry of instrument design, executed flat and precise.

Tokens.

- Palette: `#14181D` panel black (background), `#1E242B` raised surfaces, `#8DA9BF` Horizon Blue (DB 304 — primary accent: needles, active states, links), `#E8E4DA` ivory (primary text), `#C4402F` signal red (kill switches, red zones, failures only), `#5F6B5A` reseda green (success/PR-merged only). Never use red or green decoratively.
- Type: IBM Plex Sans Condensed for display/labels (gauge labels, column headers — condensed grotesks are the instrument-cluster vernacular), Inter for body, IBM Plex Mono for all numerals, IDs, transcripts, and diffs; tabular figures everywhere data appears.
- Layout: fixed left rail (nav + mode switch + master kill), content area per view; the Overview places the gauge cluster full-width at top, activity feed below-left, "needs you" queue below-right.
- Motion: needles ease to new values (300ms, respect `prefers-reduced-motion`); live transcript lines fade in; nothing else animates.

Views.

1. Overview — gauge cluster; mode indicator (PLAN-ONLY / FULL AUTO / PAUSED as a physical-feeling toggle); live activity feed; "Needs you" queue (plans ready, failed runs, escalations).
2. Issues — board: Incoming → Triaged (auto|plan chips w/ confidence) → In progress → Ready for review / PR open → Done · Failed. Cards link to issue, branch, PR, and run transcript. Promote-to-auto action on plan cards.
3. Runs — table of sessions (kind, model, turns, tokens, duration, status) + detail pane with live streaming transcript (mono, tool calls collapsed by default) and a kill button that means it.
4. Ideation — session list; per-session interactive tree (SVG, LiveView JS hook; radial or tidy-tree, node color by score, pruned branches dimmed not hidden); click node → artifact rendered in a side panel; journal strip along the bottom; "start session" form (seed, budget, mode).
5. Budget — utilization history sparklines, per-day token burn stacked by lane, Opus hours vs cap, overflow spend vs cap, annotated events (e.g., July 13 limit change).
6. Policy — pretty-rendered `policy.yaml` with inline editing + validation + diff-before-apply.

Quality floor: responsive to a narrow window (Nyel will check it from his phone via Tailscale), keyboard focus visible, empty states that tell you what to do next ("No sessions yet — seed one idea and give it three hours").

## 13. First message to send the implementing agent

Read HANDOFF-agentic-harness.md fully. Produce a Phase 0 + Phase 1 implementation plan (files you'll create, migrations, prompt templates, and how you'll test the triage JSON contract), flag anything in the spec that is ambiguous or that you'd push back on, then wait for approval.
