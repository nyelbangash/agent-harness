# Context: Provenance marker on all harness-authored GitHub bodies (#1)

## Relevant files

- `harness/lib/harness/github/plan_worker.ex:162–185` — `deliver/3` builds the issue-comment body and calls `Client.post_issue_comment`; this is write path #1 for stamping. The run_id is available one frame up in `publish/4` at line 141 via `result.run_id` and must be threaded down.
- `harness/lib/harness/github/implement_worker.ex:267–294` — `pr_body/4` builds the PR body string; this is write path #2. The `run_id` parameter is already in scope so no signature change needed — only wrap the return value.
- `harness/lib/harness/github/client.ex:61–67` — `post_issue_comment/3` is the terminal call for the plan-comment path. Its `body` argument is where the stamp must already be present before this call is made.
- `harness/lib/harness/github/client.ex:70–87` — `create_pull_request/5` is the terminal call for the PR path; same constraint.
- `harness/test/harness/github/plan_worker_test.exs:75–109` — `post_to_issue` test; needs a body-capture agent and a `harness_authored?` assertion added. The existing Req.Test stub shape matches the implement-worker test pattern (route on method+path).
- `harness/test/harness/github/implement_worker_test.exs:169–217` — `"the PR body flags test/CI file edits"` test; already captures the full PR body in an `Agent` at line 182–188. One assertion line suffices.

## Related PRs and issues

None found in git log. This is the first issue in the repo. The two write paths (`deliver`, `pr_body`) were introduced in the same initial commit as the rest of `PlanWorker` and `ImplementWorker` — no prior related changes.

## Prior art in this codebase

- **`Harness.GitHub.Triage`** (`harness/lib/harness/github/triage.ex`) — the closest structural model. It is a pure-Elixir utility module with no `use` macro, no side effects, compiled regex attributes (`@marker_re`), and a small public API (`validate/1`, `route/2`). `Provenance` should follow the same structure: module-level compiled attribute for the regex, public functions only, no `GenServer` or `Oban.Worker`.
- **Req.Test body capture pattern** in `harness/test/harness/github/implement_worker_test.exs:182–188` — uses `Plug.Conn.read_body/1` then `Jason.decode!` to extract the `"body"` key from the POST payload, stored via an `Agent`. Replicate exactly this pattern in the plan_worker test extension.
- **`alias` block conventions** — both `PlanWorker` and `ImplementWorker` maintain a grouped `alias` block after `require Logger`. New `alias Harness.GitHub.Provenance` should be added to each block in alphabetical order relative to existing aliases.
- **`String.trim_trailing` usage** — the PR body heredoc ends with a trailing newline (the `"""` closes after the last `\n`). Calling `String.trim_trailing(body)` before appending the marker prevents a double blank line between body content and the HTML comment.

## External docs

- **Elixir `Regex`** — `Regex.named_captures/2` returns a string-keyed map or `nil`; this is the idiomatic way to extract named groups. The `~r/.../` sigil compiles the regex at compile time when used as a module attribute, which is the right choice here for a hot path.
- **GitHub Markdown rendering** — HTML comments (`<!-- ... -->`) are stripped by GitHub's Markdown renderer and do not appear in the rendered view of issues, PR bodies, or comments. They are preserved in the raw body text returned by the API (the `body` field of comment/PR objects). This is the only standard mechanism for invisible machine-readable metadata in GitHub bodies.
- **`Req.Test` / `Plug.Conn.read_body/1`** — already used in the test suite. `read_body/1` returns `{:ok, binary, conn}` for small payloads (all test bodies are small). `Jason.decode!/1` then extracts the JSON-encoded request body. No new test dependencies required.
- **`Oban.Worker` / `perform/1`** — no changes to the Oban job contract; the stamp is purely a body-string transformation invisible to the job system.
