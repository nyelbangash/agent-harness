# Plan: Retry button on failed issues (no more GitHub label surgery) (#11)

## Problem restatement

When a pipeline job fails (triage, plan, or implement stage), the issue lands in `pipeline_state = "failed"` and the card sits in the "Done · Failed" column and the "Needs you" queue. The only recovery path today is external: bumping the GitHub issue's `updated_at` (e.g., toggling a label) so `PollWorker` re-enqueues the issue as if it were newly updated.

Expected behavior: an in-app "Retry" button on each failed card that re-enqueues the correct worker for the failed stage, resets `pipeline_state` so the card leaves the failed column immediately, and no-ops with a flash message if a job is already pending or executing.

---

## Implementation plan

### Step 1 — Add `latest_issue_run_kind/1` to `Harness.Runs`

**File:** `lib/harness/runs.ex`

Add a query that returns the `kind` field of the most recent run for an issue. The run kind (`"triage"`, `"plan"`, `"implement"`) identifies which pipeline stage failed and therefore which worker to re-enqueue.

```elixir
@doc "Kind of the most recent run for an issue, or nil if none exists."
def latest_issue_run_kind(issue_id) do
  from(r in Run,
    where: r.issue_id == ^issue_id,
    order_by: [desc: r.id],
    limit: 1,
    select: r.kind
  )
  |> Repo.one()
end
```

All three pipeline workers call `Runs.execute/1` before transitioning to `"failed"`, so a run record exists whenever `pipeline_state == "failed"`. The exception (failure before `execute/1`) should fall back to re-triaging (see retry handler below).

### Step 2 — Add `active_pipeline_job?/1` to `Harness.GitHub`

**File:** `lib/harness/github.ex`

Add a function that returns `true` when any of the three pipeline workers already has an active Oban job for the given issue. This mirrors the guard logic in `PollWorker.cancel_local_work/1` (lines 132–143).

```elixir
@doc "True when a triage/plan/implement Oban job is already active for the issue."
def active_pipeline_job?(issue_id) do
  import Ecto.Query

  Repo.exists?(
    from j in Oban.Job,
      where:
        j.worker in [
          "Harness.GitHub.TriageWorker",
          "Harness.GitHub.PlanWorker",
          "Harness.GitHub.ImplementWorker"
        ] and
          j.state in ["available", "scheduled", "executing", "retryable"] and
          fragment("json_extract(?, '$.issue_id') = ?", j.args, ^issue_id)
  )
end
```

Use `Repo.exists?` (not `Repo.one`) — we only need a boolean, not the job record.

### Step 3 — Add `"retry_issue"` event handler to `HarnessWeb.RailHooks`

**File:** `lib/harness_web/live/rail_hooks.ex`

Add a new clause in `handle_event/3` immediately after the existing `"promote_to_auto"` clause (line 66). The handler:

1. Checks for an already-active pipeline job and early-returns with a flash if one exists.
2. Determines the target worker from the latest run kind.
3. Transitions `pipeline_state` so the card leaves the failed column immediately (before the worker picks up the job).
4. Inserts the Oban job.

```elixir
defp handle_event("retry_issue", %{"id" => id}, socket) do
  issue_id = String.to_integer(id)

  if Harness.GitHub.active_pipeline_job?(issue_id) do
    {:halt, put_flash(socket, :info, "Already queued or running — nothing to do")}
  else
    issue = Harness.GitHub.get_issue!(issue_id)
    enqueue_retry(issue, socket)
  end
end

defp enqueue_retry(issue, socket) do
  case Harness.Runs.latest_issue_run_kind(issue.id) do
    "triage" ->
      Harness.GitHub.transition!(issue, "incoming")
      %{issue_id: issue.id} |> Harness.GitHub.TriageWorker.new() |> Oban.insert()
      {:halt, put_flash(socket, :info, "Triage re-queued")}

    "implement" ->
      Harness.GitHub.transition!(issue, "triaged")
      %{issue_id: issue.id, promoted: true} |> Harness.GitHub.ImplementWorker.new() |> Oban.insert()
      {:halt, put_flash(socket, :info, "Implement re-queued")}

    _ ->
      # "plan" or nil (no run exists — safe to re-triage first)
      # nil branch falls to plan retry since if triage succeeded a run kind
      # of "plan" would normally be present; if no run exists at all, plan
      # is still the safer choice over triage (avoids redundant model spend)
      Harness.GitHub.transition!(issue, "triaged")
      %{issue_id: issue.id} |> Harness.GitHub.PlanWorker.new() |> Oban.insert()
      {:halt, put_flash(socket, :info, "Plan re-queued")}
  end
end
```

**State-reset rationale:**
- Triage retry → `"incoming"`: matches `PollWorker.enqueue_triage/1` (line 122), which always resets to `incoming` before inserting TriageWorker.
- Plan retry → `"triaged"`: matches the convention that `PlanWorker` is inserted after triage completes with `final_route: "plan"` and a `triaged` transition (triage_worker.ex lines 219–226).
- Implement retry → `"triaged"` with `promoted: true`: matches `ImplementWorker.demote_to_plan/2` (line 246) which transitions to `triaged` before handing off. Setting `promoted: true` bypasses the full-auto mode gate (uses `Policy.gate(:plan)` instead of `Policy.gate(:implement)`), treating a manual retry as an explicit human decision — exactly analogous to the "Promote to auto" action.

### Step 4 — Add retry button to `IssuesLive.issue_card/1`

**File:** `lib/harness_web/live/issues_live.ex`

In the `issue_card/1` component (starting at line 97), add a retry button inside the card for `pipeline_state == "failed"`. Place it after the existing `failed` badge span (around line 121) or as a footer action row at the bottom of the article:

```heex
<button
  :if={@issue.pipeline_state == "failed"}
  phx-click="retry_issue"
  phx-value-id={@issue.id}
  data-confirm={"Retry #{@issue.repo}##{@issue.number}?"}
  class="mt-1.5 font-display uppercase text-[10px] tracking-widest px-1.5 py-0.5 border border-alert text-alert rounded-sm hover:bg-alert hover:text-bg"
>
  Retry
</button>
```

No new assigns are needed — `@issue.id` and `@issue.pipeline_state` are already present.

### Step 5 — Add retry button to `OverviewLive` "needs you" section

**File:** `lib/harness_web/live/overview_live.ex`

In the "needs you" section (around line 224), the card already shows a "Promote to auto" button for `plan_ready` issues. Add a retry button for `failed` issues in the same `<div>` block:

```heex
<button
  :if={issue.pipeline_state == "failed"}
  phx-click="retry_issue"
  phx-value-id={issue.id}
  data-confirm={"Retry #{issue.repo}##{issue.number}?"}
  class="px-1.5 py-0.5 border border-alert text-alert rounded-sm hover:bg-alert hover:text-bg font-display uppercase text-[10px] tracking-widest"
>
  Retry
</button>
```

Place this inside the existing `<div :if={plan = List.first(issue.plans)}>` sibling — either as a parallel `:if` block or added directly to the wrapping `<div>` at the card level (since a failed issue may have no plan). Concretely:

Add it as a top-level sibling to the `<div :if={plan = ...}>` block, directly inside the card `<div class="rounded-sm ...">`, so it shows regardless of whether a plan exists.

### Step 6 — Tests

**File:** `test/harness_web/live/overview_live_test.exs`

Add two tests (following the existing `plan_ready issues appear in the needs-you queue` test pattern):

```elixir
test "retry button on failed issue enqueues correct worker and clears failed state", %{conn: conn} do
  issue = issue_fixture(%{title: "Broken plan issue", pipeline_state: "triaged"})
  run = Runs.create_run!(%{kind: "plan", status: "failed", issue_id: issue.id, model: "sonnet", ref: "o/r##{issue.number}"})
  _failed = Harness.GitHub.transition!(issue, "failed")

  {:ok, view, html} = live(conn, ~p"/")
  assert html =~ "Broken plan issue"
  assert html =~ "failed"
  assert html =~ "Retry"

  view |> element("button", "Retry") |> render_click()

  # Oban job inserted for PlanWorker
  assert_enqueued(worker: Harness.GitHub.PlanWorker, args: %{"issue_id" => issue.id})
  # pipeline_state leaves failed
  reloaded = Harness.GitHub.get_issue!(issue.id)
  assert reloaded.pipeline_state == "triaged"
end

test "second retry click while job is pending shows flash and does not double-enqueue", %{conn: conn} do
  issue = issue_fixture(%{title: "Double-retry issue", pipeline_state: "failed"})
  _run = Runs.create_run!(%{kind: "triage", status: "failed", issue_id: issue.id, model: "sonnet", ref: "o/r##{issue.number}"})

  {:ok, view, _} = live(conn, ~p"/")

  # first click — enqueues and transitions
  Harness.GitHub.transition!(issue, "failed")
  view |> element("button", "Retry") |> render_click()
  assert_enqueued(worker: Harness.GitHub.TriageWorker, args: %{"issue_id" => issue.id})

  # simulate issue going back to failed while job still in queue
  issue = Harness.GitHub.get_issue!(issue.id)
  Harness.GitHub.transition!(issue, "failed")

  # second click — job still active, flash only
  html = view |> element("button", "Retry") |> render_click()
  assert html =~ "Already queued"
  # still only one job
  assert length(all_enqueued(worker: Harness.GitHub.TriageWorker)) == 1
end
```

**File:** `test/harness_web/live/issues_live_test.exs`

Add one test verifying the retry button appears on failed cards in the board:

```elixir
test "failed cards show a retry button", %{conn: conn} do
  issue_fixture(%{title: "Failed card", pipeline_state: "failed"})
  {:ok, _view, html} = live(conn, ~p"/issues")
  assert html =~ "Retry"
end
```

The `assert_enqueued` and `all_enqueued` helpers come from `Oban.Testing`. `DataCase` already has `use Oban.Testing, repo: Harness.Repo, engine: Oban.Engines.Lite` (line 29 of `test/support/data_case.ex`), but `ConnCase` (which LiveView tests use) does not. The test author must either add `use Oban.Testing, repo: Harness.Repo, engine: Oban.Engines.Lite` to `ConnCase`'s `using` block, or replace `assert_enqueued` / `all_enqueued` with a direct `Harness.Repo.exists?` query against `Oban.Job`.

---

## Alternatives considered

### Query Oban job history for `promoted` flag (rejected)

The triage notes that recovering the `promoted` flag for implement retries could require querying `oban_jobs` in `completed`/`discarded` states for the most recent ImplementWorker job. This is feasible (`fragment("json_extract(?, '$.promoted') = 1", j.args)`) but has two drawbacks: (1) Oban prunes completed jobs on a configurable schedule, so old failures might not have a history record; (2) it introduces a novel query pattern against Oban's internal table in a way the rest of the codebase does not.

The chosen approach sets `promoted: true` unconditionally on implement retry — a manual retry is an explicit human decision equivalent in authority to the "Promote to auto" button, so the same gate bypass is appropriate.

### Storing `is_promoted` on the Issue schema (rejected)

Adding a boolean `is_promoted` column to the `issues` table would allow the retry handler to recover the original promotion intent without querying Oban history. However, this adds schema migration complexity for a single piece of transient state. The unconditional `promoted: true` on retry makes the same semantic guarantee more simply.

### Using Oban's `conflict?` field instead of a pre-check query (not chosen)

`Oban.insert/1` returns `{:ok, %{conflict?: true}}` when a unique constraint prevents a duplicate. We could rely on this instead of the explicit `Repo.exists?` pre-check. The issue description references "same check as PollWorker line ~140" (the `cancel_local_work` query pattern), suggesting an explicit pre-check is the intended pattern. The pre-check also avoids transitioning `pipeline_state` before discovering the conflict — if we insert first and then check conflict?, the state has already changed.

---

## Open questions

1. **`nil` run kind fallback**: If `latest_issue_run_kind/1` returns `nil` (no run for the issue exists), the plan above falls back to PlanWorker with `triaged` state. An alternative is to fall back to TriageWorker with `incoming` state, which is safer but incurs model spend for a redundant triage. A human decision is needed on which is preferred; the plan defaults to PlanWorker as the more conservative choice (avoids spending a triage token if the issue already has a triage decision).

2. **Retry of triage-killed issues**: The only way an issue reaches `"failed"` via TriageWorker is `{:error, :killed}` (operator kill switch). Retrying re-queues triage. Is that the intended behavior, or should the button be labelled "Re-triage" to make the cost clear?

3. **`Oban.Testing` in `ConnCase`**: `DataCase` (`test/support/data_case.ex` line 29) already has `use Oban.Testing, repo: Harness.Repo, engine: Oban.Engines.Lite`, but `ConnCase` does not. LiveView tests use `ConnCase`. The implementer must add `use Oban.Testing, repo: Harness.Repo, engine: Oban.Engines.Lite` to `ConnCase`'s `using` block to enable `assert_enqueued`/`all_enqueued` in the new LiveView tests, or write assertions using direct `Harness.Repo.exists?(from j in Oban.Job, ...)` queries instead.
