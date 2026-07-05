# Context: Watchdog meta-monitor: /healthz endpoint + external liveness script (#2)

## Relevant files

| File | Lines | Why it matters |
|---|---|---|
| `harness/lib/harness_web/router.ex` | 13–15, 31–34 | `:api` pipeline already exists (lines 13–15); commented-out scope block (31–34) is the extension point for `/healthz`. |
| `harness/lib/harness/github/poll_worker.ex` | 26–36, 39–54 | `perform/1` is where the heartbeat stamp is added (after the `for` loop inside the `with` block). Lines 39–54 show the existing `{__MODULE__, :login}` persistent_term pattern to mirror. |
| `harness/lib/harness/policy/server.ex` | 16, 21, 30 | `@pt_key = {__MODULE__, :policy}` (line 16) is the exact key `Harness.Health` reads to assert policy is loaded. `current/0` (line 21) is the implementation behind `Harness.Policy.get/0`. |
| `harness/lib/harness/policy/schema.ex` | 59–61, 63–65, 72–84 | `GitHub` nested struct with `poll_minutes: 2` default (lines 59–61); `Notify` struct with `ntfy_topic: nil` field (63–65); top-level `Schema` struct fields (72–84) used when constructing the health test stub. |
| `harness/lib/harness/policy.ex` | 22 | `get/0` delegates to `Policy.Server.current/0`; raises if persistent_term absent — reason `Harness.Health` reads the term directly rather than calling `Policy.get/0`. |
| `harness/lib/mix/tasks/harness.install.ex` | 18, 40–63, 66–69, 71–102 | `@label`, the full plist generation template, the `uid()` helper, and the bootstrap flow — all mirrored verbatim for the watchdog plist. |
| `harness/lib/mix/tasks/harness.uninstall.ex` | 1–32 | Bootout + plist removal pattern to replicate for the watchdog label. |
| `harness/lib/mix/tasks/harness.stop.ex` | 54–63 | `launchctl bootout` pattern; watchdog bootout appended after line 63 using the same `uid` binding. |
| `harness/lib/harness/notify.ex` | 59–63, 66–79 | macOS `osascript` invocation (59–63) and ntfy.sh `POST https://ntfy.sh/#{topic}` pattern (66–79) — both replicated in shell in `ops/watchdog.sh`. |
| `harness/test/support/conn_case.ex` | 1–38 | ConnCase template: `build_conn()` + sandbox setup used by health controller tests. |
| `harness/config/config.exs` | 29–45 | Oban configuration: `engine: Oban.Engines.Lite`, `repo: Harness.Repo`, `queues: [triage: 2, implement: 1, ideate: 1, ops: 2]`. `Harness.Health.check_oban/0` iterates these queue names. |
| `ops/policy.example.yaml` | (full) | Shows `notify.ntfy_topic: null` and `github.poll_minutes: 2` defaults; reference for `read_ntfy_topic/0` key path in install task. |

---

## Related PRs and issues

- **Commit `1af60a5`** (`harness.install: bake installing shell's PATH into the generated plist`) — most recent touch to `harness.install.ex`. The watchdog plist should follow the same PATH-baking pattern if the watchdog script ever needs user-installed tools; currently it does not (uses only `/bin/sh`, `date`, `curl`, `osascript`).
- **Commit `d538ed1`** (`Untrack personal files for open-sourcing; generate launchd plist at install`) — prior plist generation refactor explaining why the plist is generated at install rather than committed to the repo. Watchdog plist follows the same philosophy.
- **No other issues or PRs found** referencing watchdog, healthz, or meta-monitoring. Git log clean on those terms.

---

## Prior art in this codebase

1. **`:persistent_term` key convention** — All uses follow `{Module, :atom_key}` tuples:
   - `{Harness.GitHub.PollWorker, :login}` at `poll_worker.ex:43`
   - `{Harness.Policy.Server, :policy}` at `server.ex:16` (via `@pt_key`)
   - `{Harness.GitHub, :last_failed_notify, issue_id}` for per-resource dedup
   - `{Harness.Usage.PollWorker, :last_budget_warn, cap}` for rate-limiting in `usage/poll_worker.ex:82–93`
   
   `Harness.Health` reads two existing keys — no new persistent_terms are introduced.

2. **plist XML template** — `plist_content/1` in `harness.install.ex:71–102` is the exact model. Watchdog plist reuses the same XML structure, substituting `<key>StartInterval</key><integer>300</integer>` for `<key>KeepAlive</key><true/>` and `ProgramArguments: ["/bin/sh", script_path]` for the caffeinate invocation.

3. **`uid()` helper** — `id -u` via `System.cmd` at `harness.install.ex:66–69`. Identical pattern needed for watchdog label bootout/bootstrap in both install and uninstall tasks.

4. **Oban worker + persistent_term coexistence** — `usage/poll_worker.ex:82–93` (`warn_once/2`) writes dedup timestamps into `:persistent_term` inside an Oban worker callback. Heartbeat write in `github/poll_worker.ex` follows the same idiom.

5. **Best-effort / never-raise notification** — `notify.ex:28–32` wraps `backend().deliver/4` in `rescue` so a failed notification never raises into the caller pipeline. The watchdog shell script uses `|| true` after the ntfy `curl` for the same reason.

6. **`ConnCase` + JSON controller test pattern** — `conn_case.ex` provides `build_conn()`, `get/2`, and `json_response/2` (from `Phoenix.ConnTest`). The health controller test follows this same setup; no new test infrastructure is needed.

7. **YamlElixir direct file read** — `policy/server.ex:60–67` reads YAML using `YamlElixir.read_from_file/1`. The install task's `read_ntfy_topic/0` reuses this call without starting the full app (install task only requires `app.config`, not the OTP application).

8. **Graceful bootout before bootstrap** — `harness.install.ex:47` runs `launchctl bootout` (ignoring exit code) before `bootstrap` to handle the re-run-after-move case. The watchdog install follows the same pattern.

---

## External docs

- **Oban 2.x** — `Oban.check_queue/1` takes a keyword list `[queue: :name]` and returns `%{queue: atom, node: binary, paused: boolean, local_limit: integer, ...}`. The 1-arity form uses the default registered Oban process (`Oban`). The 2-arity form `check_queue(name, opts)` is for explicitly-named instances. `Oban.config/0` (or `Oban.config(Oban)`) returns `%Oban.Config{}` with `queues` as a keyword list. Since the app configures Oban via `config :harness, Oban, ...` without a custom name, `Process.whereis(Oban)` resolves to the running process. **Verify actual arity** with `h Oban.check_queue` at `iex -S mix` before coding — triage flagged potential arity mismatch.

- **`:persistent_term` (Erlang stdlib, OTP 21+)** — Lock-free reads; writes trigger a global GC pass (acceptable for infrequent heartbeats and one-time loads). `get/2` (with default) is the safe read form. `erase/1` (OTP 21.3+) is available for test teardown. Since the app requires Elixir 1.15+, which mandates OTP 24+, all these functions are present.

- **`shellcheck`** — Install via `brew install shellcheck`. Key rules that apply: SC2086 (unquoted variable in double-quote context), SC2006 (backtick substitution vs `$()`), SC2039 (non-POSIX features like `local`, `[[`, `function`). Run `shellcheck ops/watchdog.sh` in CI or as a pre-commit gate.

- **launchd plist semantics** — `StartInterval` (integer seconds) fires the job repeatedly on that cadence regardless of prior exit code; unlike `KeepAlive`, it does not restart on exit (correct for a check-and-exit script). `RunAtLoad: true` causes one immediate fire on `launchctl bootstrap`. The GUI domain (`gui/<uid>`) is required for `osascript` to show banners in the logged-in user session; a system-domain agent cannot produce desktop notifications.

- **ntfy.sh HTTP API** — `POST https://ntfy.sh/<topic>` with plain-text body = notification message; `Title: <string>` header sets the notification title. No authentication for public topics. The existing Elixir code at `notify.ex:69–75` uses `Req.post` with these headers; the shell script replicates with `curl -X POST -H "Title: ..."`.

- **Phoenix controller JSON responses** — `json/2` sets `Content-Type: application/json` and encodes the map. `put_status/2` sets the HTTP status. Both are imported by `use HarnessWeb, :controller`. `json_response/2` in `Phoenix.ConnTest` decodes the body and asserts the status in one call — used in controller tests.
