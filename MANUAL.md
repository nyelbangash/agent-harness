# Harness — User Manual

The harness is a locally-run, always-on agentic development system. It watches
your GitHub issues, triages them, writes implementation plans (or implements
them outright and opens PRs), runs multi-hour ideation sessions, and shows
everything on a real-time dashboard called **Mission Control**.

This manual covers day-to-day operation. `ops/ROUTINES.md` covers the
off-machine lanes (GitHub Action, cloud/local session teleport).

---

## 1. First-time setup

Prerequisites (already true on this machine): Elixir 1.18+, the `claude` CLI
logged in to a Claude **Max** subscription (`claude auth status`), and `git`.

```sh
cd harness
mix deps.get
mix ecto.migrate
mix harness.setup        # creates ~/.harness dirs; prints the PAT command
```

### 1a. The GitHub token

Create a **fine-grained** PAT at
https://github.com/settings/personal-access-tokens with:

- **Repository access:** only the repos you'll list in policy (never work repos)
- **Permissions:** Contents *Read and write* · Issues *Read and write* ·
  Pull requests *Read and write* (Metadata read is added automatically)

Store it by running the command `harness.setup` printed, **directly in your
terminal** (input is hidden — if you can see the token as you paste, abort and
revoke it):

```sh
security add-generic-password -U -s "com.nyel.harness.github" -a "$USER" -T /usr/bin/security -w
```

Re-run the same command any time to rotate the token.

### 1b. Tell it what to watch

Edit `ops/policy.yaml`:

```yaml
github:
  repos: ["you/some-repo"]                                # plan lane only
  # or, to enable the auto lane for a repo:
  # repos: [{name: "you/some-repo", test_command: "mix test"}]
```

The file hot-reloads — no restart needed, ever.

### 1c. Health check

```sh
mix harness.doctor
```

Every row must be ✓ (the launchd row shows `!` until you install the daemon).
The doctor checks: no `ANTHROPIC_API_KEY` in the environment, claude CLI +
Max subscription auth, the PAT (Keychain + a live GitHub call), writable
directories, and a parseable policy file.

> **The #1 gotcha:** if `ANTHROPIC_API_KEY` is exported anywhere in your
> shell, the harness **refuses to boot** — on purpose. A present API key
> silently switches headless Claude from your Max subscription to
> pay-as-you-go API billing. Remove the export from your dotfiles, or prefix
> commands with `env -u ANTHROPIC_API_KEY`.

---

## 2. Running it

**Just looking / developing:**

```sh
cd harness && mix phx.server     # http://localhost:4321
```

**Always-on (the real thing):**

```sh
mix harness.install              # launchd daemon, http://localhost:4040
```

The daemon survives logout-free reboots of the app (KeepAlive), prevents the
Mac from idle-sleeping (`caffeinate`), and logs to `~/.harness/logs/`.

```sh
mix harness.stop                 # kill running agent sessions + stop daemon
mix harness.uninstall            # remove the daemon entirely
```

**From your phone:** run `tailscale serve 4040` on the Mac, then open the
Tailscale URL. The UI is responsive; never expose the port to the LAN.

Run one instance at a time. Dev (`:4321`) and prod (`:4040`) use separate
databases, but if both poll the same repos you'll pay for duplicate triage —
stop one, or blank `github.repos` in whichever you're not using.

---

## 3. The three operating modes

Set from the bottom-left toggle in Mission Control (or `mode:` in policy.yaml):

| Mode | What runs |
|---|---|
| **PLAN-ONLY** (default) | Triage + plan packets. No code is ever written. |
| **FULL AUTO** | Everything, including the implement→PR lane — but only inside `schedule.full_auto_windows` (default 20:00–06:00) and while weekly utilization is under 60%. Outside those, auto work demotes to plan. |
| **PAUSED** | All model work drains and stops. Polling continues so nothing is lost. |

The mode you set is a *ceiling*, not a guarantee — utilization gates tighten
it automatically (see §7).

---

## 4. The issue pipeline

1. **You assign yourself an issue** in a watched repo. Within ~2 minutes it
   appears in the **Issues** board's *Incoming* column.
2. **Triage** (Sonnet, ~1 min): reads the issue + comments + a repo map, and
   proposes `auto`, `plan`, or `skip` with a confidence score. Policy — not
   the model — makes the final call: `auto` requires confidence ≥ 0.75, scope
   xs/s, zero risk flags, a configured `test_command`, and FULL AUTO being
   active. Ambiguous triage (< 0.4) gets one Opus second opinion.
3. **Plan lane** (the default): a session explores the repo in a throwaway
   worktree and writes `PLAN.md` + `CONTEXT.md`. They're pushed to a
   `harness/plans/issue-N` branch (or posted as an issue comment if
   `plan.post_to_issue: true`), copied to `~/.harness/plans/`, and the card
   lands in *Ready for review* — plus the Overview's **Needs you** queue.
4. **Auto lane** (FULL AUTO only): implements in a worktree, then the
   pipeline itself runs your `test_command` (and optional `lint_command` /
   `typecheck_command`). Failures loop back to the agent up to 2 fix cycles;
   still red → demoted to the plan lane with the failure transcript. Green →
   the harness commits, pushes `harness/issue-N-slug`, opens a PR, and
   comments on the issue. **It never merges and can never push a default
   branch** — that's enforced in code, not in a prompt.
5. **Promote to auto:** any plan-ready card has a *Promote to auto* button —
   an implement session runs against the reviewed plan immediately (any mode
   except PAUSED; a human clicking is the authorization).

Special labels on issues:
- `human-only` — the harness never touches it.
- `agent-cloud` — hands the issue to the GitHub Action lane (§8); local work
  is cancelled so you don't pay twice.

---

## 5. Mission Control, view by view

- **Overview** — answers "what's happening, is it healthy, what needs me?"
  - The four gauges: 5-hour session %, weekly utilization % (both from your
    Max plan), Opus hours vs the 18 h/week cap, estimated overflow $ vs the
    $25/week cap. Red zones mark where the gates trip.
  - A red **USAGE TELEMETRY STALE** banner means the usage endpoint stopped
    answering; the system fails closed to plan-only until it recovers.
  - **Activity**: last 30 runs, live. Running rows have a per-run *Kill*.
  - **Needs you**: plans awaiting review, recent failures.
- **Issues** — the board: Incoming → Triaged (route chip + confidence + scope
  + risk flags) → In progress → Ready for review → Done · Failed. Cards link
  to the GitHub issue and PR.
- **Runs** — every agent session with turns/tokens/cost. Click a row for the
  **live transcript** (tool calls collapsed — click to expand) and a kill
  button.
- **Ideation** — see §6.
- **Budget** — utilization history sparklines, per-day token burn stacked by
  lane, cap bars, and annotated calendar events.
- **KILL ALL** (bottom-left, always visible) — kills every running agent
  session immediately. It asks once, then it means it.

---

## 6. Ideation sessions

Give it one broad thought; it grows a tree of ideas for hours.

1. Ideation view → type a seed → set a budget (default 180 min) → **Start**.
2. Each iteration is a fresh agent session: it either *diverges* (branches
   2–4 new ideas) or *develops* (researches one deeper, web search enabled),
   alternating by tree depth. The frontier is chosen by score × depth-decay,
   so it keeps exploring instead of tunnelling down one branch.
3. Every 5 iterations an **Opus critique** re-scores the frontier, prunes
   dead branches (dimmed in the tree, never deleted), and checks the work is
   still serving your seed.
4. The session stops on budget, an empty frontier, two consecutive
   critiques reporting no progress, or your **Stop** button — and always
   finishes with a **synthesis**: the 3–5 strongest branches and recommended
   next actions.

Click any node to read its full artifact. The journal strip shows the
running 3-line-per-iteration log. Everything lives on disk under
`~/.harness/ideation/session-N/` (`node-*.md`, `JOURNAL.md`, `SYNTHESIS.md`),
so it survives restarts.

Scheduling: sessions only iterate inside `schedule.ideation_windows`
(default 21:00–02:00; set `[]` for anytime) and defer automatically when
weekly utilization is over 60%.

---

## 7. Budgets and automatic brakes

Polled every 10 minutes from your Max plan's usage endpoint. As weekly
utilization climbs, the harness downshifts on its own:

| Weekly utilization | Effect |
|---|---|
| < 60% | FULL AUTO allowed |
| ≥ 60% | Ideation defers; auto lane closes |
| ≥ 80% | Plan-only, regardless of the toggle |
| ≥ 90% | Everything pauses |

Independent hard stops: **18 Opus-hours/week** and **$25/week estimated
overflow** (crossing the $ cap pauses everything). You get a macOS
notification at 80% of either cap, plus on: plan ready, PR opened, run
failed, and gates tightening. For phone pushes, set `notify.ntfy_topic` in
policy.yaml to any secret-ish topic name and subscribe to it in the ntfy app.

If the usage endpoint breaks (it's undocumented upstream), the system
assumes the worst and drops to plan-only rather than running blind.

---

## 8. When the Mac is off — the cloud lane

Copy `ops/github/agent-cloud.yml` into a target repo as
`.github/workflows/agent-cloud.yml`, generate a token with
`claude setup-token`, and add it as the repo secret `CLAUDE_CODE_OAUTH_TOKEN`.

Then: label any issue **`agent-cloud`** → GitHub Actions implements it and
opens a PR in the cloud. The local harness sees the label, cancels any local
work on that issue (no double billing), and shows a ☁ chip on the card. See
`ops/ROUTINES.md` for the other off-machine options.

---

## 9. Configuration reference (`ops/policy.yaml`)

Hot-reloads on save. A broken edit keeps the previous good config and shows
an error in the logs.

| Key | Default | Meaning |
|---|---|---|
| `mode` | `plan_only` | plan_only · full_auto · paused |
| `models.*` | claude-sonnet-5 / claude-opus-4-8 | model per stage (triage/plan/implement/ideate/critique/escalation) |
| `schedule.full_auto_windows` | `["20:00-06:00"]` | when the auto lane may run (local time) |
| `schedule.ideation_windows` | `["21:00-02:00"]` | when ideation iterates (`[]` = anytime) |
| `budgets.opus_hours_weekly_cap` | 18 | Opus wall-clock hours per trailing 7 days |
| `budgets.overflow_usd_weekly_cap` | 25 | est. overflow $ per week — crossing it pauses everything |
| `budgets.*_max_turns` | 12/40/60/25 | per-session turn caps (triage/plan/implement/ideate) |
| `utilization_gates.*` | 0.60/0.80/0.90 | the automatic downshift thresholds (§7) |
| `triage.auto_threshold` | 0.75 | min confidence for the auto route |
| `plan.post_to_issue` | false | plan packets as issue comments instead of branches |
| `implement.max_fix_cycles` | 2 | verification retry loops before demoting to plan |
| `github.repos` | `[]` | `"owner/name"` or `{name:, test_command:, lint_command:, typecheck_command:}` |
| `notify.ntfy_topic` | null | ntfy.sh topic for phone pushes |

---

## 10. Troubleshooting

**"Harness refused to boot — ANTHROPIC_API_KEY present"**
Working as intended (§1c). Remove the export from your dotfiles, or run with
`env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN mix phx.server`.

**`:eaddrinuse` — port already in use**
Another server is on that port: `lsof -ti :4321 | xargs kill` and retry.

**A card is stuck in "triaging"/"planning"**
The janitor (runs every minute) reaps orphaned runs and re-queues wedged
issues automatically — give it two minutes. If it persists, check the Runs
view for a failed session and the logs.

**PAT expired / GitHub rows red in doctor**
Fine-grained PATs expire (doctor warns 14 days out). Create a new one and
re-run the `security add-generic-password` command (§1a) — `-U` overwrites.

**Gauges read 0% with the stale banner**
The usage endpoint isn't answering (network, or Claude changed it). The
system is intentionally in plan-only. Runs still record their own rate-limit
telemetry, and everything recovers when the endpoint does.

**A run is misbehaving right now**
Kill it: the per-run *Kill* button (Runs or Activity), **KILL ALL** in the
rail, or `mix harness.stop` from a terminal.

**Logs**
Daemon: `~/.harness/logs/harness.{out,err}.log`. Dev: your terminal.

**Full environment re-check** — `mix harness.doctor`, any time.

---

## 11. Safety model (what it will never do)

- Never merges a PR. Never pushes to a default branch (only `harness/*`
  branches, force-with-lease). Enforced in code, not prompts.
- Never runs with API-key billing — boot refuses, and every agent
  subprocess gets the key scrubbed from its environment.
- Every agent session runs with an explicit tool whitelist, turn caps, and a
  wall-clock timeout, isolated from your `~/.claude` settings and from any
  `.mcp.json` in the target repo. Issue text is treated as untrusted input.
- Auto-lane PRs flag any test/CI files the agent touched — review those for
  substance, not just green checkmarks: the agent could theoretically pass
  the gate by weakening a test, and the flag makes that visible.
- Work/Main Street Health repos and credentials are entirely out of scope,
  in every lane, always.
