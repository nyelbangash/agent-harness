# Context: Retry button on failed issues (no more GitHub label surgery) (#11)

## Relevant files

| Path | Lines | Why |
|------|-------|-----|
| `lib/harness/github/poll_worker.ex` | 121–127, 131–148 | `enqueue_triage/1` — canonical pattern for transitioning to `incoming` then inserting TriageWorker; `cancel_local_work/1` — Oban active-job query pattern used for the guard (same `j.state in [...]` and `json_extract` fragment) |
| `lib/harness/github/triage_worker.ex` | 1–17, 29–52, 199–236 | Oban worker config (unique keys, states); state guards in `perform/1`; `record_and_route/2` shows how `triaged` is set before PlanWorker/ImplementWorker insert |
| `lib/harness/github/plan_worker.ex` | 44–58, 60–110 | `perform/1` cancellation guards; `plan/2` — transitions to `planning`, then to `failed` on any error; no transition back to `triaged` on error (state left as `failed`) |
| `lib/harness/github/implement_worker.ex` | 55–71, 73–78, 245–257 | `promoted` flag from job args; `gate/1` — `promoted: true` uses `Policy.gate(:plan)` (bypasses full-auto check); `demote_to_plan/2` — canonical pattern for transitioning to `triaged` before inserting PlanWorker |
| `lib/harness/github/issue.ex` | 15, 67–76 | `@pipeline_states` — all valid states; `column/1` — maps `"failed"` (and `"done"`, `"skipped"`) to the `:done` board column |
| `lib/harness/github.ex` | 83–98, 114–130 | `transition!/2` — single entry for all state changes, broadcasts `{:issue_updated, issue}`; `board/1` and `needs_attention/1` — what the two LiveViews query |
| `lib/harness/runs/run.ex` | 15–39 | `Run` schema: `kind`, `issue_id`, `status` fields; `@kinds` — valid values include `"triage"`, `"plan"`, `"implement"` |
| `lib/harness/runs.ex` | 1–168 | Context module; `create_run!/1`, `recent_runs/1`, `running_runs/1` — shows the query patterns to follow for `latest_issue_run_kind/1` |
| `lib/harness_web/live/rail_hooks.ex` | 58–66 | `promote_to_auto` event — direct template for the `retry_issue` handler: `String.to_integer(id)`, `Oban.insert`, `{:halt, put_flash(...)}` |
| `lib/harness_web/live/issues_live.ex` | 94–184 | `issue_card/1` component; lines 102–121 show where failed-state visual treatment already lives; retry button goes in this area |
| `lib/harness_web/live/overview_live.ex` | 203–244 | "Needs you" section; lines 227–236 show the existing "Promote to auto" button placement — retry button follows the same `<button :if={...}>` pattern |
| `test/support/data_case.ex` | 29 | `use Oban.Testing, repo: Harness.Repo, engine: Oban.Engines.Lite` is here (not in ConnCase) — needed for `assert_enqueued` in LiveView tests |
| `test/support/conn_case.ex` | 1–38 | Does NOT include Oban.Testing — must be updated or tests must use direct Repo queries |
| `test/harness_web/live/overview_live_test.exs` | 61–82 | `plan_ready issues appear in the needs-you queue` test — pattern to follow for retry tests: `issue_fixture`, `Runs.create_run!`, `GitHub.transition!`, `render(view)` |
| `test/support/fixtures.ex` | 1–142 | `issue_fixture/1`, `runner_result/1` — shared test helpers; `Runs.create_run!` is used directly (not via fixtures) for run records |

## Related PRs and issues

From `git log`:

- **PR #7** (`8305052`): Provenance markers — touches `rail_hooks.ex` and worker files; sets the pattern that cross-LiveView events belong in `rail_hooks.ex`.
- **PR #15** (`4c5af6a`): SQLite write-contention fix (issue #6) — confirmed that running plan + implement concurrently is now safe; relevant because a retry might start an implement job while a plan is running.
- **b7a28b5**: Split plans into their own Oban queue (`:plan` queue, concurrency 1, split from `:implement`) — the retry handler must `use` the correct queue for each worker.

No other issues or PRs directly reference retry or the label-surgery workaround in git log.

## Prior art in this codebase

### `promote_to_auto` in `rail_hooks.ex` (lines 58–66)
The exact pattern to replicate: handles a `phx-click` event in the shared hook, extracts `issue_id = String.to_integer(id)`, builds args map, calls `Worker.new() |> Oban.insert()`, returns `{:halt, put_flash(socket, :info, ...)}`. The retry handler is structurally identical, with the addition of a pre-check and a state transition.

### `cancel_local_work/1` in `poll_worker.ex` (lines 131–143)
The active-job query pattern — `from j in Oban.Job, where: j.worker in [...] and j.state in [...] and fragment("json_extract(?, '$.issue_id') = ?", j.args, ^issue.id)`. Copy this for `GitHub.active_pipeline_job?/1`.

### `enqueue_triage/1` in `poll_worker.ex` (lines 121–127)
The canonical sequence for triage retry: `GitHub.transition!(issue, "incoming")` then insert TriageWorker. This is the reference for state reset ordering (transition first, then insert).

### `demote_to_plan/2` in `implement_worker.ex` (lines 245–257)
The canonical pattern for routing to the plan lane: `GitHub.transition!(issue, "triaged")` then insert PlanWorker with optional `failure_transcript`. Retry for plan/implement follows the same `triaged` reset.

### `Oban.Worker` unique config
All three pipeline workers use `unique: [keys: [:issue_id], states: :incomplete, period: :infinity]`. This makes Oban reject duplicate inserts for the same `issue_id` while a job is in `available/scheduled/executing/retryable` states — a safety net, but the explicit pre-check still needed for the flash UX.

### `GitHub.transition!/2` broadcast
Every state change goes through this function (line 83–98 of `github.ex`). It broadcasts `{:issue_updated, issue}` on the `"issues"` PubSub topic, which causes both `IssuesLive` and `OverviewLive` to reload. Calling it before inserting the Oban job means the card leaves the failed column before the worker even picks up the job.

### Test patterns
- `issue_fixture(%{pipeline_state: "failed"})` — creates a failed issue directly.
- `Runs.create_run!(%{kind: "plan", status: "failed", issue_id: issue.id, model: "sonnet", ref: "..."})` — creates a run record without executing it (used in `overview_live_test.exs` line 63).
- `GitHub.transition!(issue, target_state)` — used inside tests to trigger LiveView updates (line 75, `overview_live_test.exs`).

## External docs

### Oban (Elixir job queue)
- **Unique jobs**: `unique: [keys: [...], states: :incomplete, period: :infinity]` means Oban prevents duplicate inserts for the same key while a job is in `[:available, :scheduled, :retryable, :executing]` states. On a unique conflict, `Oban.insert/1` returns `{:ok, %Oban.Job{conflict?: true}}` (when unique guards are active).
- **`Oban.Testing`**: Provides `assert_enqueued/1` and `all_enqueued/1` for test assertions. Must be brought in with `use Oban.Testing, repo: Repo, engine: Oban.Engines.Lite`.
- **Inline SQLite queries**: The `fragment/2` with `json_extract` is SQLite-specific JSON path syntax already used in `cancel_local_work/1`. It is the correct approach for filtering on job args in SQLite-backed Oban (vs PostgreSQL's `@>` JSON containment).

### Phoenix LiveView
- **`phx-click` + `phx-value-*`**: Standard event/value binding. The `handle_event("retry_issue", %{"id" => id}, socket)` shape matches this.
- **`{:halt, socket}`**: Stops hook chain propagation. Used by all handlers in `rail_hooks.ex` when consuming an event.
- **`put_flash/3`**: Adds a flash message; cleared on next navigation or explicit `clear_flash/1`.

### Ecto `Repo.exists?/1`
Returns a boolean — more efficient than `Repo.one` when only presence matters. Takes a query struct. Suitable for the guard check.
