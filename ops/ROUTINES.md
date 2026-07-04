# Off-machine lanes (spec §8, Phase 4)

The local daemon is the primary engine. These thin lanes cover "the Mac is
off" and "I want to teleport a session between cloud and local." All of them
converge on GitHub branches/PRs, which Mission Control's board surfaces on the
next 2-minute poll — the harness observes them, it does not orchestrate them.

## 1. GitHub Action lane (`agent-cloud`)

`ops/github/agent-cloud.yml` runs Claude Code in GitHub Actions.

**Setup (per target repo):**
1. Copy `ops/github/agent-cloud.yml` to `.github/workflows/agent-cloud.yml`.
2. `claude setup-token` → copy the `sk-ant-oat01-…` token.
3. Add it as the repo secret `CLAUDE_CODE_OAUTH_TOKEN`
   (Settings → Secrets and variables → Actions).

**Use:** label any issue `agent-cloud`. The Action implements it on a
`harness/issue-{n}-cloud` branch and opens a PR. The local poller sees the
label and **defers** the issue (skips local triage/implement) so you never
pay twice; the board shows a `☁ cloud` chip. When the cloud PR closes the
issue, it flows to Done like any other.

## 2. Claude Code Routines (scheduled recurring tasks)

For recurring cloud tasks (e.g. a nightly "triage stale issues" or "summarize
open PRs"), use Claude Code's Routines: schedule a routine from the Claude
Code web app pointed at the target repo. Output lands as issues/PRs the
harness board already tracks. No harness changes needed.

## 3. Claude Code on the web (teleport)

Start a session in the browser (claude.ai/code) against a repo, hand it off to
the local daemon by pushing a `harness/*` branch — the poller picks up the
branch/PR and it appears in Mission Control. Nothing to configure.

---

**Boundary reminder:** every one of these lanes is personal-repos-only.
Never add an MSH/work repo to any of them (spec §1, §9.7).
