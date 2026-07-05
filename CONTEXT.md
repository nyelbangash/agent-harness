# Context: Promote-to-epic: scaffold GitHub issues from a synthesized ideation branch (#5)

## Relevant files

### GitHub Client & API
- `harness/lib/harness/github/client.ex:1-141` — All existing GitHub REST calls. The `request/3` private function (lines 106-128) handles auth, versioning, and pluggable test options via `:github_req_options`. New `create_issue/4` and `update_issue/3` follow this pattern exactly. The existing `post_issue_comment/3` (line 61) is the closest structural analogue for `create_issue/4`.

### Oban Workers (pattern reference)
- `harness/lib/harness/github/plan_worker.ex:1-207` — The closest pattern for PromoteWorker: rides `:implement` queue, policy gate check, `Runs.execute/1` with a RunSpec, DB record before irreversible external publish (line 133), `try/after` for cleanup.
- `harness/lib/harness/ideation/critique_worker.ex:14-54` — Inline JSON schema as module attribute (lines 18-39); `:json` output mode; Elixir-side structured_output validation pattern. PromoteWorker should define its contract schema the same way.
- `harness/lib/harness/ideation/iteration_worker.ex:33-55` — Two JSON schemas as module attributes (diverge + develop). Demonstrates the pattern of multiple schemas in one worker.
- `harness/lib/harness/github/triage_worker.ex:100-142` — Contract retry pattern and validation flow. PromoteWorker does not need a retry (non-idempotent writes), but the validation shape (`Triage.validate/1` equivalent) is the right model.
- `harness/lib/harness/github/implement_worker.ex:54-69` — The `promoted: true` args flag and `Policy.gate(:plan)` bypass pattern shows how Oban args carry behavioral modifiers.
- `harness/lib/harness/github/poll_worker.ex:38-54` — `assignee_login/0` with `:persistent_term` cache; PromoteWorker needs the same to self-assign issues.

### Ideation context & schema
- `harness/lib/harness/ideation.ex:1-241` — Context module with tree queries, broadcasts, and artifact helpers. `ancestor_chain/1` (line 158) and `tree/1` (line 99) are what PromoteWorker uses to build context. `subtree/1` is new and must be added here.
- `harness/lib/harness/ideation/idea.ex:1-54` — Idea schema. `@statuses ~w(seed frontier expanded pruned synthesized)` (line 10). No new status needed; promotion state lives in `ideation_promotions`.
- `harness/lib/harness/ideation/session.ex:1-59` — Session schema. `synthesis_path` (line 27) is set when status becomes "synthesized". PromoteWorker gates on `session.status in ["synthesized", "stopped"]` or checks score only — see open questions in PLAN.md.

### Policy
- `harness/lib/harness/policy.ex:54-64` — `gate/2` function. PromoteWorker does NOT call `Policy.gate/1` (no model-lane gate for a human-initiated action); it does its own simpler check: `mode == :paused` and `repo not in policy.github.repos`.
- `harness/lib/harness/policy/schema.ex:59-69, 185-223` — `GitHub` substruct (line 60), `Repo` substruct (line 67-70), `parse_github/1` (line 185). The `policy.github.repos` list (of `%Repo{name: ...}` structs) is what PromoteWorker validates `target_repo` against. UI select options come from `Enum.map(policy.github.repos, & &1.name)`.

### Prompts
- `harness/lib/harness/prompts.ex:1-157` — Template rendering, truncation limits, and `sanitize/1` (line 152). All prompt functions follow `render(template, assigns)`. New `promote/4` goes here.
- `ops/prompts/triage.md.eex:1-58` — Defines what "scores well": xs/s scope, locatable code references, acceptance criteria, confidence calibration. The promote template must instruct the model to write children meeting these criteria explicitly.
- `ops/prompts/synthesis.md.eex:1-26` — Closest template in terms of reading artifacts and producing structured prose from the tree. The promote template follows the same "read artifacts, be decisive" instruction style.
- `ops/prompts/plan.md.eex:1-68` — Shows the full plan prompt structure; the `CONTEXT.md` required structure section shows how the harness asks the model to cite file:line-range — useful reference for how to ask for "locatable code references" in child issue bodies.

### Runs infrastructure
- `harness/lib/harness/runs/run_spec.ex:1-40` — `RunSpec` struct. `kind` type must include `:promote`. `output_mode: :json` with `json_schema` is what PromoteWorker uses (same as triage, iteration, critique workers). `cwd` will be `Ideation.session_dir(session)` — an existing directory the model can read artifacts from.
- `harness/lib/harness/runs.ex:1-129` — `execute/1` entry point (line 25). Broadcasts `{:run_started}` and `{:run_updated}`. PromoteWorker's run will appear in RunsLive at `/runs` automatically with kind "promote".

### LiveView
- `harness/lib/harness_web/live/ideation_live.ex:1-280` — The full IdeationLive. The selected_node panel (lines 238-256) is where the promote button and epic URL go. The `select_node` handler (line 65) is where `promotion: Ideation.latest_promotion(idea.id)` must be added. The `handle_info` catchall (line 90) is where `{:promotion_completed, promotion}` clause is inserted before.
- `harness/lib/harness_web/live/rail_hooks.ex:58-66` — The existing `promote_to_auto` event and `handle_event` hook pattern. The new promote affordance in IdeationLive uses the same `phx-click` → `handle_event` → `Oban.insert` shape, but in the view module directly (not via RailHooks) since it carries session-specific context.
- `harness/lib/harness_web/router.ex:20-28` — `live_session :mission_control` with `on_mount: [HarnessWeb.RailHooks]`. No new routes needed; IdeationLive at `/ideation/:id` already exists.

### Tests (reference patterns)
- `harness/test/harness/github/client_test.exs:1-68` — Req.Test stub pattern: `Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})`, `Req.Test.stub/2`, inspect `conn.method`, `conn.request_path`, headers. Use this exact setup for `create_issue` and `update_issue` tests.
- `harness/test/harness/github/plan_worker_test.exs:1-159` — `FakeRunner.script/1` with a fn that writes files or returns canned results. `perform_job/2` pattern. The `writes_artifacts` helper (line 32) shows how to inject side effects in the runner fn. PromoteWorker tests use the same approach to return a canned promote contract.
- `harness/test/harness/ideation/workers_test.exs:1-217` — Ideation worker test structure with `enable_ideation!()` setup helper (from `Harness.Fixtures`), `FakeRunner.script/1`, `perform_job/2`. PromoteWorker tests should follow this module's structure closely.
- `harness/test/harness_web/live/ideation_live_test.exs:1-68` — LiveView test pattern: `live(conn, ~p"/ideation/#{session.id}")`, `render_click`, `render_submit`. The `form/2` + `render_submit/0` pattern is used for the modal confirm form.
- `harness/test/support/fake_runner.ex:1-98` — FakeRunner records all executed RunSpecs in `executed_specs/0`. Tests should assert `spec.kind == :promote`, `spec.output_mode == :json`, `spec.json_schema` matches the expected schema.
- `harness/test/support/fixtures.ex:60-63` — `runner_result(attrs)` builder. `runner_result(structured_output: %{"epic" => ..., "children" => [...]})` is how you inject the canned promote contract.

### Migrations (reference)
- `harness/priv/repo/migrations/20260704000010_create_ideation.exs:1-45` — The ideation tables migration. New `ideation_promotions` migration follows the same structure (foreign keys, indexes, `timestamps(type: :utc_datetime_usec)`).
- `harness/priv/repo/migrations/20260704000007_create_plans.exs:1-19` — The `plans` table is the closest domain analogue (run result → external publish). The `ideation_promotions` table mirrors its shape (run_id reference, nullable url, status field).

### Provenance marker (on branch, not on master)
- Commit `ed62b8c` on `harness/issue-1-provenance-marker-on-all-harness-authore` introduced `harness/lib/harness/github/provenance.ex` (28 lines). The module is `Harness.GitHub.Provenance` with `stamp(body, kind, ref)` → appends `<!-- harness:v1 kind=K ref=R -->`. Its test is at `harness/test/harness/github/provenance_test.exs`. This file does NOT exist on master as of the worktree baseline. Implementer must check if it has been merged; if not, recreate it.

## Related PRs and issues

- **Issue #1 (provenance marker)** — branch `harness/issue-1-provenance-marker-on-all-harness-authore`, commit `ed62b8c`. Directly referenced in issue #5 ("Every body passes through the provenance marker (#1) before posting"). Merge status is unknown; the branch is ahead of master.
- **Issue #2** — "Watchdog meta-monitor" (`harness/plans/issue-2` branch). Unrelated to this work.
- **Issue #3** — "Triage calibration ledger" (`harness/plans/issue-3` branch). Unrelated.
- **Issue #6** — "SQLite write contention" (`harness/plans/issue-6` branch). The `:immediate` transaction mode fix there (config.exs line 25) is already in master and protects the new `ideation_promotions` writes.

## Prior art in this codebase

### Pattern: Oban worker on `:implement` queue for sequential GitHub writes
`PlanWorker` and `ImplementWorker` both ride `:implement` (concurrency 1) because their work is irreversible external API writes that must not run concurrently per issue. PromoteWorker follows the same reasoning (epic + children creation is sequential and non-idempotent). Queue at `config.exs:31`.

### Pattern: Inline JSON schema as module attribute
`CritiqueWorker` (lines 17-39) and `IterationWorker` (lines 33-68) define their JSON schema contracts as `@schema Jason.encode!(...)` module attributes. PromoteWorker's `@promote_schema` follows the same pattern exactly, defining the `{epic, children}` contract.

### Pattern: Req.Test for GitHub API stubs
Every test that touches the GitHub client sets `Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})` in setup and stubs via `Req.Test.stub/2`. Tests are `async: false` because the env key is global. Promote worker tests need the same setup (plus FakeRunner for the model call).

### Pattern: `create_promotion!` before irreversible external publish
`PlanWorker.publish/3` records the plan in the DB (line 133) *before* posting to GitHub/pushing the branch, so that a DB failure after an external publish doesn't cause a re-run to double-publish. PromoteWorker follows: record promotion row (status "running") before any `create_issue` calls; update incrementally as each step completes.

### Pattern: `:persistent_term` viewer login cache
`PollWorker.assignee_login/0` (lines 38-54) caches the PAT owner's login in `:persistent_term` to avoid repeated `GET /user` calls. PromoteWorker needs the login for `assignees:` in `create_issue`. Copy the same caching pattern (same key space risk: use `{Harness.Ideation.PromoteWorker, :login}` as key to avoid collision).

### Pattern: Partial-failure comment on epic, no delete
The issue's failure semantics ("comment the failure on the epic rather than deleting") is consistent with the overall harness philosophy of preferring forward progress and audit trails over rollback. `ImplementWorker` similarly comments on the issue when work is done (`Client.post_issue_comment` at line 228). PromoteWorker posts the same kind of failure comment when a child creation fails mid-sequence.

### Pattern: broadcast on session-scoped topic for live updates
`Ideation.broadcast/2` (line 24-27) pushes to both `"ideation"` (session list) and `"ideation:#{id}"` (single session). `IdeationLive.handle_info/2` already subscribes to `"ideation:#{id}"` via `Ideation.subscribe(id)` in `handle_params/3` (line 34). A new `{:promotion_completed, promotion}` broadcast on `"ideation:#{session_id}"` will be received by the live view without any new PubSub setup.

### Pattern: Policy repo validation by name
`ImplementWorker.implement/2` (lines 81-93) validates the repo by `Enum.find(policy.github.repos, &(&1.name == issue.repo))`. PromoteWorker does the same: `repo in Enum.map(policy.github.repos, & &1.name)` for the guard check, and the UI select is pre-populated from the same list so the submitted value is always valid.

### Pattern: LiveView assigns for modal state
No existing modals in the codebase — the "Promote to auto" in `OverviewLive` uses `data-confirm` (a browser confirm dialog). The promote epic modal is the first true in-view modal. Use a simple `promote_modal: nil | %{idea: idea}` assign as the toggle; this is idiomatic Phoenix LiveView (no JS hooks needed for simple show/hide).

## External docs

### GitHub REST API
- **Create an issue**: `POST /repos/{owner}/{repo}/issues`. Body: `{title, body, assignees, labels, milestone}`. Returns 201 with `{number, html_url, ...}`. Reference: `https://docs.github.com/en/rest/issues/issues#create-an-issue`. The fine-grained PAT already used in the harness carries Issues RW scope (confirmed in client.ex module doc, line 5).
- **Update an issue**: `PATCH /repos/{owner}/{repo}/issues/{issue_number}`. Body: same fields as create. Returns 200. Reference: `https://docs.github.com/en/rest/issues/issues#update-an-issue`. This is what the epic body patch uses after child links are known.
- **API versioning**: header `X-GitHub-Api-Version: 2022-11-28` (defined at `client.ex:16`). All new calls inherit this via `request/3`.

### Oban
- **`Oban.Worker`**: `use Oban.Worker, queue: :queue_name, max_attempts: N, unique: [keys: [...], ...]`. The `:implement` queue is configured at concurrency 1 in `config.exs:31`. `unique: [keys: [:idea_id, :target_repo], states: :incomplete, period: :infinity]` prevents duplicate promote jobs for the same node+repo while one is pending/executing.
- **`Oban.insert/1`**: synchronous insert; returns `{:ok, job}` or `{:error, changeset}`.
- **`perform_job/2`** in tests: provided by `Oban.Testing` (via `DataCase`). Runs the job synchronously in the test process.

### Req / Req.Test
- **`Req.Test.stub/2`**: replaces the HTTP layer for a named plug module. Stubs are process-local in async-false tests (global env key). The existing test pattern in `client_test.exs:14-18` is the definitive reference.
- **`Req.request/1` with `:patch` method**: Req supports all HTTP methods via `method:` option. The existing `request/3` private function passes `method: method` directly to `Req.request/1`, so `:patch` works without changes.

### Phoenix LiveView
- **`assign/3` for modal toggle**: idiomatic — no `JS.show/hide` hooks needed for a server-driven modal. The `promote_modal` assign controls visibility via `:if={@promote_modal}`.
- **`phx-submit` on a form inside a modal**: submits via LiveView websocket, triggers `handle_event("promote", params, socket)`. The form element's `name` attributes populate `params`.
- **`on_mount` hook in RailHooks**: The `attach_hook(:rail_events, :handle_event, &handle_event/3)` at line 26 intercepts all handle_event calls before the live view's own handlers. Any new event name ("show_promote_modal", "cancel_promote", "promote") not handled in RailHooks falls through via `{:cont, socket}` at line 68 to IdeationLive's own `handle_event` clauses.

### Ecto
- **`Repo.insert!/1`** with timestamps: The migration uses `timestamps(type: :utc_datetime_usec)` (consistent with all other tables). The schema uses `timestamps(type: :utc_datetime_usec)`.
- **`from(p in Promotion, where: ..., order_by: [desc: p.id], limit: 1)`**: standard one-row query pattern used throughout (`latest_triage/1` at `github.ex:141` is identical in shape to `latest_promotion/1`).
