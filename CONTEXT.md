# Context: SQLite write contention: 'Database busy' crashed a live plan run (#6)

## Relevant files

| Path | Line range | Why it matters |
|------|-----------|----------------|
| `harness/config/config.exs` | 22–27 | Repo config block: sets `default_transaction_mode: :immediate` and `pool_size: 5`; missing `busy_timeout` is root cause #1 |
| `harness/config/runtime.exs` | 29–37 | Prod Repo override: sets `database` and `pool_size`; must also receive `busy_timeout` to avoid confusion if block is ever replaced wholesale |
| `harness/lib/harness/runs/run_server.ex` | 109–111 | `handle_info({port, {:data, chunk}})` — unhandled `Exqlite.Error` here crashes the GenServer |
| `harness/lib/harness/runs/run_server.ex` | 162–169 | `ingest_chunk/2` — non-JSON clause calls `Enum.reduce` per line; target of both the batch-transaction change and the rescue wrapper |
| `harness/lib/harness/runs/run_server.ex` | 176–211 | `ingest_line/2` — calls `EventIngest.ingest/3` which triggers `Repo.insert!` (one transaction per line) |
| `harness/lib/harness/runs/run_server.ex` | 215–247 | `drain_buffer/2` — processes at most one event at end of stream; no batching needed here |
| `harness/lib/harness/runs/run_server.ex` | 36–58 | `init/1` state map — new `pending_events` field (if accumulator approach is chosen) would go here |
| `harness/lib/harness/runs/event_ingest.ex` | 27–44 | `ingest/3` — does JSON decode, `categorize`, `Repo.insert!`, and `side_effects` all inline; the single-insert hot path |
| `harness/lib/harness/runs/event_ingest.ex` | 78–82 | `side_effects/3` — calls `Usage.ingest_rate_limit_event/2` on overage events; must remain callable on retry (it upserts) |
| `harness/lib/harness/runs.ex` | 44–59 | `append_event!/4` — the per-event `Repo.insert!` + PubSub broadcast that will be wrapped in the batch transaction |
| `harness/lib/harness/runs/runner/claude_cli.ex` | 25–38 | `execute/2` catch block — currently catches GenServer crashes and writes `status: "failed"`, `error: "runner crashed: ..."`. After the fix this path should be unreachable for DB-busy errors |
| `harness/lib/harness/runs/run_event.ex` | 12–33 | `RunEvent` schema — unique constraint `(run_id, seq)` means batch retries are idempotent; no duplicate-event risk on retry |
| `harness/priv/repo/migrations/20260704000005_create_run_events.exs` | 1–17 | Confirms `unique_index(:run_events, [:run_id, :seq])` — safe to retry failed transactions |
| `harness/test/harness/runs/run_server_test.exs` | 20–28 | `stub_executable/2` helper — the pattern to replicate in the new contention test |
| `harness/test/harness/runs/run_server_test.exs` | 30–44 | `spec/2` and `execute/1` helpers — model for the contention test's helpers |
| `harness/test/support/data_case.ex` | 41–44 | `setup_sandbox` with `shared: not tags[:async]` — with `async: false` all spawned processes share the sandbox without explicit `allow/3` |
| `harness/test/support/fixtures/ndjson/happy_tool_use.ndjson` | 1–10 | 10-line fixture used by run_server_test; the contention test asserts exactly 10 events per run against this file |

## Related PRs and issues

None found in git log. All commits preceding this issue are feature/phase deliveries (`Phase 1`–`Phase 4`) and tooling/docs commits. No prior fixes to `event_ingest`, `run_server`, or SQLite config. The `busy_timeout` gap is a first-occurrence oversight, not a regression.

## Prior art in this codebase

### Transaction mode config precedent
`config.exs` lines 22–27 already document and set `default_transaction_mode: :immediate` for exactly the same class of SQLite concurrency problem (DEFERRED→write upgrade causing immediate BUSY). The `busy_timeout` addition follows the same pattern and the same comment block.

### `async: false` + `shared` sandbox for spawned-process tests
`run_server_test.exs` uses `async: false` and spawns real `RunServer` GenServer processes via `Runner.ClaudeCLI.execute`. The test works without explicit `Ecto.Adapters.SQL.Sandbox.allow/3` calls because `DataCase.setup_sandbox` starts the owner in `shared: true` mode. The new contention test follows this same pattern exactly.

### `stub_executable` pattern
`run_server_test.exs` lines 20–28: a temp shell script set via `Application.put_env(:harness, :claude_executable, path)`, cleaned up with `on_exit`. This is the only way to test the real `RunServer` + `EventIngest` path (the configured `:runner` is `FakeRunner` in tests). The contention test must follow this pattern.

### Bounded retry with backoff
No prior retry helpers exist in this codebase. The approach (rescue, check message, `Process.sleep` with exponential backoff, max attempts) is idiomatic Elixir and consistent with the explicit error handling style seen in `claude_cli.ex` (catch `:exit, reason`, update run, return `{:error, :runner_crash}`).

### Per-chunk `handle_info` processing
The Port delivers data in chunks; the existing `ingest_chunk` splits on `"\n"` and processes all lines from one `:data` message in a single `Enum.reduce`. One `Repo.transaction` call wrapping that reduce is the natural batch boundary — it mirrors how `ingest_chunk` already treats a chunk as one logical unit.

### PubSub broadcast inside `append_event!`
`runs.ex` line 57: `Phoenix.PubSub.broadcast` is called inside `append_event!` after `Repo.insert!` but before the caller returns. When `append_event!` is called inside a `Repo.transaction`, the broadcast happens before commit. This is the current semantics (each auto-commit insert already broadcasts before the next insert). The wrapping transaction does not change the observable order from subscribers' perspective.

## External docs

### ecto_sqlite3 — `busy_timeout`
`ecto_sqlite3` accepts a `busy_timeout: integer` (milliseconds) option in the Repo config. It maps directly to SQLite's `PRAGMA busy_timeout = N`. With `default_transaction_mode: :immediate`, the `BEGIN IMMEDIATE` statement will block for up to `busy_timeout` ms before raising SQLITE_BUSY instead of failing instantly. The recommended value for this use case (single-user daemon, short write transactions) is 5 000 ms.

### Exqlite.Error
`Exqlite.Error` is the exception raised by `exqlite` (the NIF library under `ecto_sqlite3`) when SQLite returns an error code. Its `message` field contains the SQLite error string (e.g., `"Database busy"`). It is not wrapped by `ecto_sqlite3` or `DBConnection` before reaching application code — the prod crash log confirms `%Exqlite.Error{message: "Database busy"}` is what propagates through `Repo.insert!`.

### Ecto `Repo.transaction/1`
When a function passed to `Repo.transaction/1` raises, the transaction is rolled back and the exception is re-raised from `Repo.transaction`. Nested `Repo.transaction` calls inside the function create SQLite SAVEPOINTs (because SQLite does not support true nested transactions), so `append_event!` called inside the wrapping transaction will use a savepoint rather than a new `BEGIN IMMEDIATE`. This is safe and correct.

With `default_transaction_mode: :immediate`, the outer `BEGIN IMMEDIATE` acquires the write lock once for the whole chunk. Inner savepoints do not re-acquire the lock.

### Ecto SQL Sandbox — shared mode
`Ecto.Adapters.SQL.Sandbox.start_owner!(repo, shared: true)` makes the sandbox connection available to all processes without calling `allow/3`. This is required for tests that spawn GenServer or Task processes (like `RunServer` via `ClaudeCLI.execute`). The existing `DataCase.setup_sandbox` already uses this mode for `async: false` tests.

### SQLite WAL
Journal mode is WAL (Write-Ahead Logging, set by ecto_sqlite3 by default). WAL allows one writer and many concurrent readers. Writer-writer contention (two simultaneous `BEGIN IMMEDIATE`) is resolved by the write lock: the second writer blocks for `busy_timeout` ms, then either proceeds (if the lock is free) or raises SQLITE_BUSY. `busy_timeout` is the primary knob for tolerating transient write contention.
