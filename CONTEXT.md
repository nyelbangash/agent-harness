# Context: Triage calibration ledger: record real outcomes per triage decision (#3)

## Relevant files

- `harness/priv/repo/migrations/20260704000006_create_triages.exs` (lines 5–22): `triages` schema — FKs and column style that `triage_outcomes` mirrors; shows `on_delete: :delete_all` vs `on_delete: :nilify_all` precedent.
- `harness/priv/repo/migrations/20260704000003_create_issues.exs` (lines 5–27): `issues` table to be altered (Step 1, add `auto_demoted`); shows column style and index conventions.
- `harness/priv/repo/migrations/20260704000009_add_pr_to_issues.exs` (lines 1–10): canonical `alter table` migration style for adding columns to `issues`; Step 1 follows this exactly.
- `harness/lib/harness/github/issue.ex` (lines 17–65): `Issue` schema and changeset; `auto_demoted` field and `has_many :outcomes` association go here.
- `harness/lib/harness/github/triage_decision.ex` (lines 15–57): `TriageDecision` schema — FK target for `triage_outcomes.triage_id`; `final_route` field is used by `classify_outcome/1` to distinguish `plan_executed` from `merged_*`.
- `harness/lib/harness/github/client.ex` (lines 89–128): `find_pull_request/2` and private `request/3` — the exact pattern the two new public functions (`get_pull_request/2`, `list_pull_request_commits/2`) must follow.
- `harness/lib/harness/github/poll_worker.ex` (lines 152–169): `reconcile_closed/2` — where the capture hook is added; lines 56–82 show the `poll_repo/3` flow that calls it.
- `harness/lib/harness/github/implement_worker.ex` (lines 244–256): `demote_to_plan/2` — needs one new line to set `auto_demoted: true` before `GitHub.transition!/2`.
- `harness/lib/harness/github.ex` (lines 133–144): `record_triage!/1` and `latest_triage/1` — direct pattern match for the new `record_triage_outcome!/1`; `latest_triage/1` is already correct for finding the decisive triage.
- `harness/lib/harness/runs/run_event.ex` (lines 12–21): `RunEvent` schema — has non-null `run_id` FK; explains why outcome events use `:telemetry.execute/3` instead of `append_event!/4`.
- `harness/test/harness/github/client_test.exs` (lines 1–68): Req.Test stubbing setup, `async: false` pattern, and assertion style for new `get_pull_request/2` and `list_pull_request_commits/2` tests.
- `harness/test/harness/github/poll_worker_test.exs` (lines 1–166): Full test structure to extend for outcome capture tests; `stub_issues/2` helper and `reset_poll_clock/0` are both reused.
- `harness/test/support/fixtures.ex` (lines 7–59): `issue_fixture/1` and `gh_issue_payload/1` — both needed in new triage outcome and poll worker tests.
- `harness/test/support/data_case.ex` (lines 19–44): `DataCase` template; all new tests `use Harness.DataCase, async: false`.

## Related PRs and issues

None found in git log or issue references. The schema (`triages`, `run_events`, `issues.pr_number`) was introduced in the initial batch of migrations all sharing timestamp `20260704000XXX`, so there is no prior iteration to reference.

## Prior art in this codebase

**Upsert-ignore pattern.** `Harness.GitHub.record_plan!/1` (github.ex lines 148–154) supersedes old `ready` plans with `Repo.update_all(set: [status: "superseded"])` before inserting. For outcomes the unique constraint + `on_conflict: :nothing` is preferred because capture must be idempotent, not replace.

**`latest_triage/1`** (github.ex lines 141–144) is already the function to call for the decisive triage — it returns the highest-id `TriageDecision` for an issue. All triages have a non-null `final_route` (required in the changeset), so no filtering is needed.

**ETag-first poll design.** The existing poller (poll_worker.ex lines 56–82) aggressively avoids unnecessary work: ETags make idle polls free. The capture hook must not call GitHub APIs on every poll tick — only when an issue has actually closed. Wiring into `reconcile_closed/2` satisfies this because that function only executes on the subset of tracked issues missing from the open listing.

**Req.Test stubbing via application env.** Client tests (client_test.exs lines 7–11) and poll worker tests (poll_worker_test.exs lines 13–14) both inject `plug: {Req.Test, __MODULE__}` through `:github_req_options`. All HTTP calls in `Client.request/3` (client.ex line 123) pick this up. New tests for `get_pull_request/2` and `list_pull_request_commits/2` use the same mechanism — no change to `request/3` needed.

**`async: false` convention.** Every test file that swaps application env (`:github_req_options`, `:policy_path`) or touches the database uses `async: false`. Both the new schema test and the extended poll worker test must follow this (see DataCase, line 42: `shared: not tags[:async]`).

**`on_delete: :delete_all` vs `on_delete: :nilify_all`.** In the triages migration, `issue_id` uses `delete_all` and `run_id` uses `nilify_all`. The outcomes migration follows the same logic: `issue_id` cascades (no orphan outcomes), `triage_id` nilifies (triage rows may be pruned independently).

**`:telemetry.execute/3` vs PubSub vs run_events.** Existing domain events use PubSub (`broadcast/1` in github.ex line 173 and runs.ex line 126) and are typed for live-view consumption. Run events (run_event.ex) are tied to a specific run. Outcome events have neither property — they are metric-shaped (one-time, aggregate-friendly). `:telemetry.execute/3` is already wired into the app via `HarnessWeb.Telemetry` and is the correct primitive for "Mission Control can chart later" use.

**`@moduletag :capture_log`.** All github worker test modules set this tag (poll_worker_test.exs line 8). New tests should follow suit since `capture_outcome/1` logs a warning on PR fetch failure.

## External docs

- **GitHub REST API — Pull Requests:** `GET /repos/{owner}/{repo}/pulls/{pull_number}` returns a PR object including `state` ("open"|"closed"), `merged` (boolean), and `merge_commit_sha` (string|null). `GET /repos/{owner}/{repo}/pulls/{pull_number}/commits` returns a list of commit objects; pagination applies (max 250 per page), but the harness always creates exactly one commit per PR, so `per_page: 100` is sufficient.
- **Req library:** The codebase uses `Req` (not HTTPoison or Tesla). `Req.request/1` with `method`, `url`, `headers`, `params`, `json` keys matches the existing usage. `Req.Test` provides `stub/2` and `json/2` for test mocking.
- **Oban — `on_conflict` inserts:** Ecto's `Repo.insert!/2` accepts `on_conflict: :nothing` and `conflict_target: [:col]` which map to SQLite's `INSERT OR IGNORE` semantics. This is the idempotency mechanism for re-polls.
- **`:telemetry` (Erlang telemetry library):** `:telemetry.execute(event_name, measurements, metadata)` fires a synchronous event to all attached handlers. Event names are lists of atoms by convention (`[:harness, :triage, :outcome_recorded]`). Handlers attach via `:telemetry.attach/4`. No handler needs to exist at capture time; the event is fire-and-forget.
- **Ecto SQLite adapter:** Migrations use `Ecto.Migration` DSL (`create table`, `alter table`, `add`, `references`). `async: false` in tests is required because SQLite is a single-writer database — the sandbox uses a global mutex already, but concurrent tests that modify schema state would race.
