# Plan: Watchdog meta-monitor: /healthz endpoint + external liveness script (#2)

## Problem restatement

The harness daemon is its own only observer. When the installed LaunchAgent plist becomes stale (after a repo move, for example), the daemon silently stops and nobody knows. A process that is up but wedged — Oban stalled, poll loop frozen, policy not loaded — also produces no signal. `launchd`'s `KeepAlive` only covers crash-restart; it cannot detect an unloaded plist or a live-but-broken process.

The fix has three interlocking parts: (1) a `/healthz` JSON endpoint the daemon exposes about its own internals; (2) a POSIX shell watchdog that polls that endpoint from outside the Elixir runtime (so it fails independently); and (3) install-task changes that place the watchdog under its own `launchd` service with a 5-minute cadence.

Expected behaviour after the change: within 5 minutes of the daemon going down or becoming unhealthy, the user sees a macOS notification and (if configured) an ntfy.sh message. On recovery, a second notification fires. The watchdog suppresses repeat alerts to at most one per hour while the daemon remains down.

---

## Implementation plan

### Step 1 — Heartbeat stamp in `Harness.GitHub.PollWorker`

**File:** `harness/lib/harness/github/poll_worker.ex`, `perform/1` (lines 26–36)

Add one line inside the `with` block, after the `for` loop closes (after line 33, before `end`):

```elixir
:persistent_term.put({__MODULE__, :last_sweep_at}, System.system_time(:second))
```

Full updated `perform/1`:

```elixir
def perform(_job) do
  policy = Harness.Policy.get()

  with {:ok, login} <- assignee_login() do
    for repo <- policy.github.repos do
      poll_repo(repo, login, policy.github.poll_minutes)
    end

    :persistent_term.put({__MODULE__, :last_sweep_at}, System.system_time(:second))
  end

  :ok
end
```

Placing it inside the `with` block means the stamp only advances when login resolves — a stale or missing PAT does not masquerade as a healthy sweep. The key `{Harness.GitHub.PollWorker, :last_sweep_at}` mirrors the existing `{__MODULE__, :login}` pattern at line 43.

---

### Step 2 — New module `Harness.Health`

**New file:** `harness/lib/harness/health.ex`

```elixir
defmodule Harness.Health do
  @pt_poll_key {Harness.GitHub.PollWorker, :last_sweep_at}
  # mirrors @pt_key in harness/lib/harness/policy/server.ex:16
  @pt_policy_key {Harness.Policy.Server, :policy}

  def check do
    results = [check_oban(), check_poll_heartbeat(), check_policy()]
    failing = for {:error, name} <- results, do: name

    if failing == [],
      do: {:ok, %{"status" => "ok"}},
      else: {:error, %{"status" => "degraded", "failing" => failing}}
  end

  defp check_oban do
    # Oban is registered as `Oban` when configured via `config :harness, Oban, ...`
    case Process.whereis(Oban) do
      nil ->
        {:error, "oban"}

      _pid ->
        queues = Oban.config().queues
        any_paused = Enum.any?(queues, fn {q, _} ->
          try do
            Map.get(Oban.check_queue(queue: q), :paused, false)
          rescue
            _ -> false
          catch
            :exit, _ -> true
          end
        end)

        if any_paused, do: {:error, "oban"}, else: :ok
    end
  end

  defp check_poll_heartbeat do
    case :persistent_term.get(@pt_poll_key, nil) do
      nil ->
        {:error, "poll_heartbeat"}

      ts ->
        max_age_s = get_poll_minutes() * 3 * 60
        if System.system_time(:second) - ts <= max_age_s,
          do: :ok,
          else: {:error, "poll_heartbeat"}
    end
  end

  defp check_policy do
    case :persistent_term.get(@pt_policy_key, nil) do
      nil -> {:error, "policy"}
      _ -> :ok
    end
  end

  defp get_poll_minutes do
    case :persistent_term.get(@pt_policy_key, nil) do
      nil -> 2
      policy -> policy.github.poll_minutes
    end
  end
end
```

**Oban API note:** `Oban.check_queue/1` (taking `[queue: name]`) is the 1-arity form for the default Oban instance. The 2-arity `Oban.check_queue(name, opts)` is for explicitly-named instances. Verify the exact arity against `h Oban.check_queue` in `iex -S mix` before committing (see Open questions). `Oban.config().queues` returns the keyword list from config — same `[triage: 2, implement: 1, ideate: 1, ops: 2]` declared in `harness/config/config.exs:34`.

`get_poll_minutes` reads the policy persistent_term directly (rather than calling `Harness.Policy.get/0` which raises if the term is absent) so `check_poll_heartbeat` does not depend on `check_policy` succeeding first.

---

### Step 3 — New `HarnessWeb.HealthController`

**New file:** `harness/lib/harness_web/controllers/health_controller.ex`

```elixir
defmodule HarnessWeb.HealthController do
  use HarnessWeb, :controller

  def index(conn, _params) do
    case Harness.Health.check() do
      {:ok, body} -> json(conn, body)
      {:error, body} -> conn |> put_status(503) |> json(body)
    end
  end
end
```

---

### Step 4 — Add `/healthz` route to router

**File:** `harness/lib/harness_web/router.ex`

The `:api` pipeline already exists at lines 13–15. Replace the commented-out example block (lines 31–34) with a real scope:

```elixir
scope "/", HarnessWeb do
  pipe_through :api
  get "/healthz", HealthController, :index
end
```

Do not add this route inside the `:browser` scope — it must avoid CSRF protection (`protect_from_forgery`) and session plugs.

---

### Step 5 — Create `ops/watchdog.sh`

**New file:** `ops/watchdog.sh`

Plain POSIX shell (`#!/bin/sh`, no bashisms). Must pass `shellcheck ops/watchdog.sh` clean.

State file format: `<status> <epoch_seconds>` on one line, written atomically via `printf ... > file`.

State machine:
| Previous state | Current result | Action |
|---|---|---|
| (none / first run) | up | Write `up <now>`. Silent. |
| (none / first run) | down | Notify "Harness is DOWN". Write `down <now>`. |
| up | down | Notify "Harness is DOWN". Write `down <now>`. |
| down | down | Notify "still DOWN" only if `now - last_ts >= 3600`. Update ts if notified. |
| down | up | Notify "Harness RECOVERED". Write `up <now>`. |
| up | up | Write `up <now>`. Silent. |

Initial state with no state file is treated as "was up" — prevents a false alarm on a healthy initial install.

```sh
#!/bin/sh
# External liveness watchdog for the harness daemon.
# Polls /healthz and alerts on state transitions (down/recovered) plus
# at most one reminder per hour while down.
# NTFY_TOPIC is baked into the launchd environment by mix harness.install.

HEALTHZ="http://127.0.0.1:4040/healthz"
STATE_FILE="${HOME}/.harness/watchdog_state"
TITLE="Harness Watchdog"

notify() {
  msg="$1"
  osascript -e "display notification \"${msg}\" with title \"${TITLE}\""
  if [ -n "${NTFY_TOPIC}" ]; then
    curl -s -X POST "https://ntfy.sh/${NTFY_TOPIC}" \
      -H "Title: ${TITLE}" \
      -d "${msg}" || true
  fi
}

now=$(date +%s)

if curl -fsS --max-time 10 "${HEALTHZ}" >/dev/null 2>&1; then
  current=up
else
  current=down
fi

if [ -f "${STATE_FILE}" ]; then
  read -r prev_status prev_ts < "${STATE_FILE}"
else
  prev_status=up
  prev_ts=0
fi

case "${current}:${prev_status}" in
  down:up|down:)
    notify "Harness is DOWN — check logs at ~/.harness/logs/"
    printf 'down %s\n' "${now}" > "${STATE_FILE}"
    ;;
  down:down)
    age=$((now - prev_ts))
    if [ "${age}" -ge 3600 ]; then
      notify "Harness still DOWN (reminder)"
      printf 'down %s\n' "${now}" > "${STATE_FILE}"
    fi
    ;;
  up:down)
    notify "Harness RECOVERED"
    printf 'up %s\n' "${now}" > "${STATE_FILE}"
    ;;
  up:*)
    printf 'up %s\n' "${now}" > "${STATE_FILE}"
    ;;
esac
```

---

### Step 6 — Update `Mix.Tasks.Harness.Install`

**File:** `harness/lib/mix/tasks/harness.install.ex`

Add a module attribute and three new private functions; extend `run/1`.

```elixir
@watchdog_label "com.nyel.harness.watchdog"
```

New private functions:

```elixir
defp read_ntfy_topic do
  path = Application.fetch_env!(:harness, :policy_path)
  case YamlElixir.read_from_file(path) do
    {:ok, %{"notify" => %{"ntfy_topic" => topic}}} when is_binary(topic) and topic != "" ->
      topic
    _ ->
      nil
  end
end

defp watchdog_plist_content(script_path, ntfy_topic) do
  env_block =
    if ntfy_topic do
      """
          <key>NTFY_TOPIC</key><string>#{ntfy_topic}</string>
      """
    else
      ""
    end

  """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
    <key>Label</key><string>#{@watchdog_label}</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/sh</string><string>#{script_path}</string>
    </array>
    <key>StartInterval</key><integer>300</integer>
    <key>RunAtLoad</key><true/>
    <key>EnvironmentVariables</key>
    <dict>#{env_block}</dict>
  </dict></plist>
  """
end

defp install_watchdog(home) do
  project_root = Application.fetch_env!(:harness, :project_root)
  src = Path.join([project_root, "ops", "watchdog.sh"])
  dest = Path.join(home, "watchdog.sh")

  File.cp!(src, dest)
  File.chmod!(dest, 0o755)
  Mix.shell().info("  ✓ #{dest}")

  ntfy_topic = read_ntfy_topic()
  watchdog_plist = Path.expand("~/Library/LaunchAgents/#{@watchdog_label}.plist")
  File.write!(watchdog_plist, watchdog_plist_content(dest, ntfy_topic))
  Mix.shell().info("  ✓ #{watchdog_plist}")

  System.cmd("launchctl", ["bootout", "gui/#{uid()}/#{@watchdog_label}"],
    stderr_to_stdout: true
  )

  case System.cmd("launchctl", ["bootstrap", "gui/#{uid()}", watchdog_plist],
         stderr_to_stdout: true
       ) do
    {_, 0} ->
      Mix.shell().info("  ✓ bootstrapped gui/#{uid()}/#{@watchdog_label}")

    {output, code} ->
      Mix.raise("launchctl bootstrap (watchdog) exited #{code}: #{String.trim(output)}")
  end
end
```

At the end of `run/1`, after the existing bootstrap success message (after line 63), call:

```elixir
install_watchdog(home)
```

---

### Step 7 — Update `Mix.Tasks.Harness.Uninstall`

**File:** `harness/lib/mix/tasks/harness.uninstall.ex`

After removing the main plist (after line 30), add the same pattern for the watchdog:

```elixir
@watchdog_label "com.nyel.harness.watchdog"

# (inside run/1, after existing plist removal)
watchdog_label = "com.nyel.harness.watchdog"
System.cmd("launchctl", ["bootout", "gui/#{uid}/#{watchdog_label}"],
  stderr_to_stdout: true
)

watchdog_plist = Path.expand("~/Library/LaunchAgents/#{watchdog_label}.plist")
if File.exists?(watchdog_plist) do
  File.rm!(watchdog_plist)
  Mix.shell().info("  ✓ removed #{watchdog_plist}")
end
```

Extract the `uid` computation into a shared `defp uid` function (currently duplicated across tasks as inline variable on line 17). Both tasks can call `uid()` — or use a shared helper if extracted to a common module.

---

### Step 8 — Update `Mix.Tasks.Harness.Stop`

**File:** `harness/lib/mix/tasks/harness.stop.ex`

After the existing `launchctl bootout` for the main daemon (after line 63), add watchdog bootout so the watchdog does not alert during an intentional stop:

```elixir
System.cmd("launchctl", ["bootout", "gui/#{uid}/com.nyel.harness.watchdog"],
  stderr_to_stdout: true
)
Mix.shell().info("  · watchdog stopped (resumes after next harness.install)")
```

Note: `harness.stop` deliberately leaves the daemon installed (plist remains); watchdog bootout mirrors that — the plist stays, but the service is not running. A subsequent `mix harness.install` will re-bootstrap both.

---

### Step 9 — Tests

#### 9a. Controller/health test

**New file:** `harness/test/harness_web/controllers/health_controller_test.exs`

```elixir
defmodule HarnessWeb.HealthControllerTest do
  use HarnessWeb.ConnCase

  @pt_poll_key {Harness.GitHub.PollWorker, :last_sweep_at}
  @pt_policy_key {Harness.Policy.Server, :policy}

  # Minimal policy stub — only the fields health.ex reads
  defp stub_policy do
    %Harness.Policy.Schema{
      github: %Harness.Policy.Schema.GitHub{poll_minutes: 2}
    }
  end

  setup do
    prev_poll   = :persistent_term.get(@pt_poll_key, :missing)
    prev_policy = :persistent_term.get(@pt_policy_key, :missing)

    on_exit(fn ->
      restore = fn key, prev ->
        if prev == :missing,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, prev)
      end
      restore.(@pt_poll_key, prev_poll)
      restore.(@pt_policy_key, prev_policy)
    end)

    :persistent_term.put(@pt_policy_key, stub_policy())
    :ok
  end

  test "200 ok when heartbeat is fresh and policy is loaded", %{conn: conn} do
    :persistent_term.put(@pt_poll_key, System.system_time(:second))
    conn = get(conn, "/healthz")
    assert json_response(conn, 200)["status"] == "ok"
  end

  test "503 names poll_heartbeat when stamp is stale", %{conn: conn} do
    stale_ts = System.system_time(:second) - 999
    :persistent_term.put(@pt_poll_key, stale_ts)
    conn = get(conn, "/healthz")
    body = json_response(conn, 503)
    assert body["status"] == "degraded"
    assert "poll_heartbeat" in body["failing"]
  end

  test "503 names poll_heartbeat when no sweep has occurred", %{conn: conn} do
    :persistent_term.erase(@pt_poll_key)
    conn = get(conn, "/healthz")
    assert "poll_heartbeat" in json_response(conn, 503)["failing"]
  end

  test "503 names policy when policy is not loaded", %{conn: conn} do
    :persistent_term.put(@pt_poll_key, System.system_time(:second))
    :persistent_term.erase(@pt_policy_key)
    conn = get(conn, "/healthz")
    assert "policy" in json_response(conn, 503)["failing"]
  end
end
```

The Oban check passes in tests because `Process.whereis(Oban)` returns the Oban pid started by `use Oban.Testing` in `DataCase`. A dedicated Oban-failure test would require a separate named Oban instance or mocking `Process.whereis` — defer to follow-up if needed.

#### 9b. Shell watchdog test

**New file:** `ops/test_watchdog.sh`

Uses POSIX function overriding to stub `curl`, `osascript`, and `date`. Tests three transitions: initial-down, persist-down (suppress within 1 hour), recover.

```sh
#!/bin/sh
# Test harness for ops/watchdog.sh — no external dependencies.
set -e

TMPDIR=$(mktemp -d)
STATE_FILE="${TMPDIR}/watchdog_state"
HOME="${TMPDIR}"
export HOME STATE_FILE

pass=0
fail=0

check() {
  label="$1"; expected="$2"; actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $label"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label — expected='$expected' got='$actual'"
    fail=$((fail + 1))
  fi
}

# --- Stubs ---
NOTIFIED=""
osascript() { NOTIFIED="${NOTIFIED}osascript:$*|"; }
export -f osascript 2>/dev/null || true  # bash; sh sourcing handles this via .

# curl stub controlled by STUB_EXIT
STUB_EXIT=1  # default: fail (daemon down)
curl() { return $STUB_EXIT; }

FAKE_NOW=1000
date() { echo "$FAKE_NOW"; }

# Source watchdog (redefine functions without executing main body)
# Split into sourced functions vs entry point for testability.
# The script must define functions separately from the main block,
# or tests source it after stubbing shell builtins.

# --- Test 1: initial state, daemon down → alert ---
rm -f "${STATE_FILE}"
NOTIFIED=""
STUB_EXIT=1
FAKE_NOW=1000
. ./ops/watchdog.sh
check "initial-down triggers notification" "1" "$(echo "$NOTIFIED" | grep -c osascript)"
check "state file written as down" "down" "$(awk '{print $1}' "$STATE_FILE")"

# --- Test 2: down→down within 1 hour → suppressed ---
printf 'down 999\n' > "${STATE_FILE}"  # 1 second ago, well within 3600
NOTIFIED=""
FAKE_NOW=1000
STUB_EXIT=1
. ./ops/watchdog.sh
check "repeat within 1 hour is suppressed" "0" "$(echo "$NOTIFIED" | grep -c osascript)"

# --- Test 3: down→down after 1 hour → reminder fires ---
printf 'down 0\n' > "${STATE_FILE}"   # 1000 seconds ago (> 3600 needs bigger gap)
FAKE_NOW=4000
NOTIFIED=""
STUB_EXIT=1
. ./ops/watchdog.sh
check "reminder fires after 1 hour" "1" "$(echo "$NOTIFIED" | grep -c osascript)"

# --- Test 4: down→up → recovery notice ---
printf 'down 0\n' > "${STATE_FILE}"
NOTIFIED=""
STUB_EXIT=0
FAKE_NOW=5000
. ./ops/watchdog.sh
check "recovery triggers notification" "1" "$(echo "$NOTIFIED" | grep -c osascript)"
check "state file written as up" "up" "$(awk '{print $1}' "$STATE_FILE")"

# --- Test 5: up→up → silent ---
printf 'up 0\n' > "${STATE_FILE}"
NOTIFIED=""
STUB_EXIT=0
. ./ops/watchdog.sh
check "up→up is silent" "0" "$(echo "$NOTIFIED" | grep -c osascript)"

rm -rf "${TMPDIR}"
echo ""
echo "Results: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
```

Note: the test script sources `watchdog.sh` using `.` (dot); for this to work, `watchdog.sh` must structure its main logic inside a block that can be overridden by pre-sourced stubs. An alternative is to make the watchdog's body a `main` function called at end of file, so tests can source, redefine stubs, then call `main`. The plan leaves the exact source/run boundary to the implementer; the test structure above documents the intent.

---

## Alternatives considered

1. **Health GenServer instead of direct persistent_term reads**: A dedicated GenServer could aggregate health status and cache it. Rejected — persistent_term reads are already the lock-free hot path used throughout the codebase (see `Policy.Server.current/0`). A GenServer adds a process hop and is itself a potential point of failure, ironic for a health check.

2. **Expose ntfy config to watchdog by reading `ops/policy.yaml` at check time**: The watchdog would read the YAML on each 5-minute invocation. Rejected — the watchdog's purpose is to be outside the app's failure domain. If the app is wedged, the policy path resolution (which relies on the app's `Application.fetch_env!` being loaded from a prod plist) cannot be trusted. Baking `NTFY_TOPIC` into the launchd environment at install time keeps the watchdog independent, at the cost of requiring reinstall if the ntfy topic changes.

3. **Co-process the watchdog in the main daemon plist** (e.g., a second program in the same service): Rejected — if the main launchd service is unloaded or its plist becomes stale, a co-process defined in that plist is also unloaded. The watchdog needs its own independent launchd service.

4. **Add `/healthz` under the `:browser` pipeline**: The `:browser` pipeline includes `protect_from_forgery` and session plugs that add overhead and require a session cookie. Rejected — health checks are machine-to-machine; the existing `:api` pipeline (already defined at lines 13–15) is correct.

---

## Open questions

1. **`Oban.check_queue` arity in Oban 2.23**: The triage summary flags that the issue cites `Oban.check_queue/2` but Oban 2.23 may use `/1`. The plan uses `Oban.check_queue(queue: q)` (1-arity, default instance). Implementer must verify with `h Oban.check_queue` in `iex -S mix` before committing `Harness.Health`. If only `/2` exists, the call becomes `Oban.check_queue(Oban, queue: q)`.

2. **Oban healthz in test environment**: The `DataCase` template uses `use Oban.Testing, repo: Harness.Repo, engine: Oban.Engines.Lite`. It is possible that `Oban.check_queue` behaves differently (or raises) under the inline test Oban. If the controller tests fail on the Oban check, add a `:health_oban_check` config escape that can be set to `:skip` in `config/test.exs`.

3. **Watchdog shell test source-level reuse**: The test plan above sources `watchdog.sh` with `.`; this works if the script's main body can be re-entered with stubbed functions. If the script uses subshells or `exec`, sourcing won't override builtins. The implementer may need to restructure the watchdog into a `main()` function called at the bottom, so tests can source, override, then call `main`.

4. **ntfy_topic re-baking on policy change**: If a user adds an `ntfy_topic` to `policy.yaml` after initial install, they must re-run `mix harness.install` for the watchdog plist to pick it up. This is consistent with how the main plist handles PATH changes (documented in `harness.install.ex:9-10`). No code change needed — document in the install task's `@moduledoc`.

5. **No prompt injection detected**: The issue body is clean and consistent with prior work in this repository. No injection attempt was found.
