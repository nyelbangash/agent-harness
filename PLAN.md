# Plan: SQLite write contention: 'Database busy' crashed a live plan run (#6)

## Problem restatement

**Expected behavior**: Multiple concurrent `RunServer` processes streaming NDJSON events should persist all events reliably even under concurrent write pressure from Oban workers and `PollWorker` upserts.

**Actual behavior**: `Runs.append_event!` → `Repo.insert!` opens a fresh `BEGIN IMMEDIATE` transaction per event. SQLite allows only one writer at a time; with no `busy_timeout` configured, any write that arrives while the lock is held returns `SQLITE_BUSY` immediately (it does not queue). `ecto_sqlite3` propagates this as `Exqlite.Error: Database busy`. In `RunServer`, this exception travels through `EventIngest.ingest/3` → `ingest_line/2` → the `Enum.reduce` in `ingest_chunk/2` → `handle_info({port, {:data, chunk}}, state)`, crashing the GenServer. The Oban attempt is burned, the run is lost, and the OS claude process is left as a ghost until `terminate/2` cleans up. This was run 8, 2026-07-05 05:07 UTC.

There are three compounding causes:
1. No `busy_timeout`: writers fail instantly instead of queuing.
2. One transaction per event: N events per Port chunk = N write lock acquisitions, maximising contention window.
3. No exception boundary: an `Exqlite.Error` in the ingest path kills the whole GenServer rather than being retried.

---

## Implementation plan

### Step 1 — Set `busy_timeout` in Repo config (xs)

**`harness/config/config.exs`, lines 25–27** — add `busy_timeout: 5_000` so SQLite queues writers for up to 5 s before returning SQLITE_BUSY:

```elixir
config :harness, Harness.Repo,
  default_transaction_mode: :immediate,
  pool_size: 5,
  busy_timeout: 5_000
```

**`harness/config/runtime.exs`, lines 35–37** — add the same key to the prod override block. Config keyword lists merge, so `config.exs` values survive a runtime.exs override, but being explicit is safer if the prod block is ever replaced wholesale:

```elixir
config :harness, Harness.Repo,
  database: database_path,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
  busy_timeout: 5_000
```

`busy_timeout` maps directly to SQLite's `PRAGMA busy_timeout` and is honoured by ecto_sqlite3's Exqlite connection layer. It applies at the connection level, so all callers (Oban, RunServer, PollWorker) benefit automatically.

---

### Step 2 — Batch event ingest + retryable busy error (m + s, combined in one file)

Both changes land entirely in **`harness/lib/harness/runs/run_server.ex`**. No changes to `EventIngest` or `Runs.append_event!` are needed.

**Add alias** at the top of the module (alongside existing aliases):

```elixir
alias Harness.Repo
```

**Replace `ingest_chunk/2`** (currently lines 166–169, the non-JSON clause):

```elixir
# Before:
defp ingest_chunk(state, chunk) do
  {lines, rest} = split_lines(state.buffer <> chunk)
  Enum.reduce(lines, %{state | buffer: rest}, &ingest_line(&2, &1))
end

# After:
@max_busy_retries 3

defp ingest_chunk(state, chunk) do
  {lines, rest} = split_lines(state.buffer <> chunk)
  do_ingest_with_retry(state, lines, rest, 0)
end

defp do_ingest_with_retry(state, lines, rest, attempt) do
  try do
    {:ok, new_state} =
      Repo.transaction(fn ->
        Enum.reduce(lines, %{state | buffer: rest}, &ingest_line(&2, &1))
      end)

    new_state
  rescue
    e in Exqlite.Error ->
      if String.contains?(Exception.message(e), "busy") and attempt < @max_busy_retries do
        Process.sleep(trunc(50 * :math.pow(2, attempt)))
        do_ingest_with_retry(state, lines, rest, attempt + 1)
      else
        Logger.error("run #{state.run.id} ingest batch failed: #{Exception.message(e)}")
        %{state | buffer: rest}
      end
  end
end
```

**Batching semantics**: All `Repo.insert!` calls inside the `Enum.reduce` (via `EventIngest.ingest/3` → `Runs.append_event!`) now share one `BEGIN IMMEDIATE` transaction, reducing N write lock acquisitions per chunk to 1.

**Retry semantics**: On `Exqlite.Error` with "busy" in the message (and `busy_timeout` already waited its full 5 s), the transaction has been rolled back. The retry re-runs the full reduce from the original `state`; it is safe because:
- All in-flight `run_events` inserts were rolled back — no partial writes.
- `do_kill` (SIGTERM send) is idempotent: signalling an already-terminating process is harmless.
- `Usage.ingest_rate_limit_event` (called by `side_effects` inside `ingest_line`) is an upsert — safe to retry.
- After `@max_busy_retries` exhausted, the chunk's events are logged and dropped; the run continues rather than crashing.

**Scope of change**: The `:json` mode clause of `ingest_chunk` (line 162–164) and both `drain_buffer` clauses (lines 215–247) are unchanged — `:json` mode buffers without inserting, and `drain_buffer` handles at most one event per invocation.

---

### Step 3 — Acceptance / regression test (m)

**New file**: `harness/test/harness/runs/contention_test.exs`

Uses `stub_executable` (same pattern as `run_server_test.exs`) to run two concurrent `Runner.ClaudeCLI.execute` tasks that each stream `happy_tool_use.ndjson` (10 events), while a concurrent writer task does repeated `Runs.create_run!` inserts to simulate Oban/PollWorker pressure. `async: false` with shared SQL sandbox (the existing pattern throughout this test suite).

```elixir
defmodule Harness.Runs.ContentionTest do
  use Harness.DataCase, async: false

  alias Harness.Runs
  alias Harness.Runs.{Runner, RunSpec}

  @moduletag :capture_log

  @fixtures Path.expand("../../support/fixtures/ndjson", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "contention-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp stub_executable(tmp, body) do
    path = Path.join(tmp, "claude-stub")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    Application.put_env(:harness, :claude_executable, path)
    on_exit(fn -> Application.delete_env(:harness, :claude_executable) end)
    path
  end

  defp spec(tmp) do
    %RunSpec{
      kind: :plan,
      model: "sonnet",
      prompt: "contention test",
      cwd: tmp,
      allowed_tools: [],
      max_turns: 10
    }
  end

  test "two concurrent runs with concurrent DB writer: no crash, all events persisted", %{tmp: tmp} do
    stub_executable(tmp, ~s(cat "#{@fixtures}/happy_tool_use.ndjson"\n))

    # Simulates Oban / PollWorker write pressure: 30 inserts at ~5 ms intervals
    # while both run sessions are actively streaming events.
    writer =
      Task.async(fn ->
        for _ <- 1..30 do
          Runs.create_run!(%{kind: "plan", status: "running", model: "sonnet"})
          Process.sleep(5)
        end
      end)

    t1 = Task.async(fn -> Runner.ClaudeCLI.execute(spec(tmp), []) end)
    t2 = Task.async(fn -> Runner.ClaudeCLI.execute(spec(tmp), []) end)

    Task.await(writer, 5_000)
    assert {:ok, %Runner.Result{run_id: id1}} = Task.await(t1, 15_000)
    assert {:ok, %Runner.Result{run_id: id2}} = Task.await(t2, 15_000)
    assert id1 != id2

    # Regression: run 8's failure mode (runner crashed: Exqlite.Error Database busy)
    # cannot recur — all 10 events per run must be persisted.
    assert length(Runs.events(id1)) == 10
    assert length(Runs.events(id2)) == 10
  end
end
```

**Why `Runner.ClaudeCLI` directly** (not `Runs.execute`): The test config sets `config :harness, :runner, Harness.Runs.FakeRunner`, so `Runs.execute/1` would bypass the real ingest path. Calling `Runner.ClaudeCLI.execute/2` directly matches the approach in `run_server_test.exs` and exercises the actual `RunServer` + `EventIngest` + `Repo.insert!` chain.

**Sandbox compatibility**: With `async: false`, `DataCase.setup_sandbox` starts the sandbox in `shared: true` mode. All spawned Tasks and RunServer GenServer processes can use the sandbox connection without explicit `Sandbox.allow/3` calls — this is the existing pattern verified by the existing RunServer tests.

---

## Alternatives considered

### Global write-serialisation GenServer
The issue non-goals explicitly rule this out unless batching proves insufficient. It would serialise every write behind a single GenServer call, eliminating contention but adding latency and a hot bottleneck to every Oban job, poll sweep, and ingest call.

### `Ecto.Repo.insert_all` for true bulk SQL
`insert_all/3` would submit all chunk events in one SQL `INSERT` statement, reducing per-chunk overhead further. However, it requires separating decode/categorise from persistence in `EventIngest.ingest/3`, complicating the API (tests call `ingest/3` directly and expect single-event inserts); and it requires either a `returning:` roundtrip to get struct IDs for PubSub broadcasts or a separate re-query. The per-chunk transaction already collapses N write lock acquisitions to 1 — the dominant win — without any API surface changes. `insert_all` is a follow-on micro-optimisation if profiling warrants it.

### Increasing `pool_size`
SQLite WAL allows concurrent readers but only one writer at a time regardless of pool size. A larger pool improves reader concurrency but does nothing for the write contention described in this issue.

---

## Open questions

None — the issue is fully specified with a concrete prod failure and acceptance criteria. Implementation can proceed without human input.

(No injection attempts detected in the issue body.)
