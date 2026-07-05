# Plan: Triage calibration ledger: record real outcomes per triage decision (#3)

## Problem restatement

The harness predicts a triage route (`auto` / `plan` / `skip`) for every issue and records that decision in the `triages` table. After an issue closes — by PR merge, manual close, or abandoned PR — nothing writes back to say what actually happened. The `triage.auto_threshold` and `low_confidence_floor` policy knobs can therefore only be tuned by feel, not data. This issue adds the capture side: a `triage_outcomes` table that records one row per closed issue, classifying what happened relative to the harness's prediction. Analysis and reporting are explicitly out of scope.

There is one design gap the triage identified: `ImplementWorker.demote_to_plan/2` transitions the issue back to `triaged` with no distinguishing mark, so the PollWorker cannot later tell a "demoted-from-auto" issue from one that was always plan-routed. Step 1 resolves this.

## Implementation plan

### Step 1 — Migration: add `auto_demoted` column to `issues`

**File (new):** `harness/priv/repo/migrations/20260704000012_add_auto_demoted_to_issues.exs`

```elixir
defmodule Harness.Repo.Migrations.AddAutoDemotedToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :auto_demoted, :boolean, null: false, default: false
    end
  end
end
```

This single boolean resolves the demoted-detection gap. All existing issues default to `false`.

---

### Step 2 — Migration: create `triage_outcomes` table

**File (new):** `harness/priv/repo/migrations/20260704000013_create_triage_outcomes.exs`

```elixir
defmodule Harness.Repo.Migrations.CreateTriageOutcomes do
  use Ecto.Migration

  def change do
    create table(:triage_outcomes) do
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :triage_id, references(:triages, on_delete: :nilify_all)
      add :outcome, :string, null: false
      add :resolved_at, :utc_datetime_usec, null: false
      add :days_open, :float, null: false
      add :amend_commit_count, :integer           # nullable
      add :shadow, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:triage_outcomes, [:issue_id])
    create index(:triage_outcomes, [:outcome])
    create index(:triage_outcomes, [:triage_id])
  end
end
```

The unique index on `issue_id` is the idempotency guard — re-polls hit `on_conflict: :nothing`.

---

### Step 3 — New Ecto schema: `Harness.GitHub.TriageOutcome`

**File (new):** `harness/lib/harness/github/triage_outcome.ex`

```elixir
defmodule Harness.GitHub.TriageOutcome do
  use Ecto.Schema
  import Ecto.Changeset

  @outcomes ~w(merged_untouched merged_amended pr_closed_unmerged
               plan_executed issue_closed_no_action demoted)

  schema "triage_outcomes" do
    belongs_to :issue, Harness.GitHub.Issue
    belongs_to :triage, Harness.GitHub.TriageDecision

    field :outcome, :string
    field :resolved_at, :utc_datetime_usec
    field :days_open, :float
    field :amend_commit_count, :integer
    field :shadow, :boolean, default: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def outcomes, do: @outcomes

  def changeset(to, attrs) do
    to
    |> cast(attrs, [:issue_id, :triage_id, :outcome, :resolved_at,
                    :days_open, :amend_commit_count, :shadow])
    |> validate_required([:issue_id, :outcome, :resolved_at, :days_open])
    |> validate_inclusion(:outcome, @outcomes)
    |> unique_constraint(:issue_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:triage_id)
  end
end
```

---

### Step 4 — Update `Harness.GitHub.Issue` schema

**File:** `harness/lib/harness/github/issue.ex`

Add to the `schema "issues"` block (after the `:pr_number` field):
```elixir
field :auto_demoted, :boolean, default: false
has_many :outcomes, Harness.GitHub.TriageOutcome
```

Add `:auto_demoted` to the `cast/2` list in `changeset/2`. No inclusion validation needed (boolean).

---

### Step 5 — New client functions in `Harness.GitHub.Client`

**File:** `harness/lib/harness/github/client.ex`

Add two public functions following the `find_pull_request/2` pattern (lines 89–104):

```elixir
@doc "Fetch a single PR by number. Returns at least state, merged, merge_commit_sha."
def get_pull_request(repo, number) do
  case request(:get, "/repos/#{repo}/pulls/#{number}") do
    {:ok, %{status: 200, body: %{"state" => state, "merged" => merged,
                                 "merge_commit_sha" => sha}}} ->
      {:ok, %{state: state, merged: merged, merge_commit_sha: sha}}

    {:ok, %{status: 404}} ->
      {:error, :not_found}

    {:ok, %{status: status}} ->
      {:error, {:http_status, status}}

    {:error, reason} ->
      {:error, reason}
  end
end

@doc "List commits on a PR (up to 100). Used for amended-vs-untouched attribution."
def list_pull_request_commits(repo, number) do
  case request(:get, "/repos/#{repo}/pulls/#{number}/commits",
               params: [per_page: 100]) do
    {:ok, %{status: 200, body: commits}} when is_list(commits) ->
      {:ok, commits}

    {:ok, %{status: status}} ->
      {:error, {:http_status, status}}

    {:error, reason} ->
      {:error, reason}
  end
end
```

---

### Step 6 — Add outcome helpers to `Harness.GitHub` context

**File:** `harness/lib/harness/github.ex`

Add `alias Harness.GitHub.TriageOutcome` to the alias block.

Add two new public functions after the `latest_triage/1` function (line 144):

```elixir
@doc """
Insert exactly one outcome row per issue (idempotent — unique index on issue_id,
on_conflict: :nothing).
"""
def record_triage_outcome!(attrs) do
  %TriageOutcome{}
  |> TriageOutcome.changeset(attrs)
  |> Repo.insert!(on_conflict: :nothing, conflict_target: [:issue_id])
end
```

`days_open` is the caller's responsibility: `DateTime.diff(resolved_at, issue.inserted_at, :second) / 86400.0`.

---

### Step 7 — Mark `auto_demoted` in `ImplementWorker.demote_to_plan/2`

**File:** `harness/lib/harness/github/implement_worker.ex`

Replace the current `demote_to_plan/2` body (lines 244–256):

```elixir
defp demote_to_plan(issue, transcript) do
  # Flag for outcome capture — PollWorker cannot otherwise distinguish a
  # demoted-auto issue from one that was always plan-routed.
  issue =
    issue
    |> Harness.GitHub.Issue.changeset(%{auto_demoted: true})
    |> Harness.Repo.update!()

  GitHub.transition!(issue, "triaged")

  args =
    if transcript do
      %{issue_id: issue.id, failure_transcript: String.slice(transcript, 0, 8_000)}
    else
      %{issue_id: issue.id}
    end

  args |> Harness.GitHub.PlanWorker.new() |> Oban.insert()
  :ok
end
```

---

### Step 8 — Capture hook in `PollWorker.reconcile_closed/2`

**File:** `harness/lib/harness/github/poll_worker.ex`

Extend `reconcile_closed/2` (lines 152–169) to pipe through `capture_outcome/1` after the
`GitHub.transition!("done")` call:

```elixir
defp reconcile_closed(repo_name, issues) do
  open_numbers = MapSet.new(issues, & &1["number"])

  GitHub.board()
  |> Map.values()
  |> List.flatten()
  |> Enum.filter(fn issue ->
    issue.repo == repo_name and issue.state == "open" and
      issue.pipeline_state not in ["done", "failed", "skipped"] and
      not MapSet.member?(open_numbers, issue.number)
  end)
  |> Enum.each(fn issue ->
    issue
    |> Harness.GitHub.Issue.changeset(%{state: "closed"})
    |> Harness.Repo.update!()
    |> GitHub.transition!("done")
    |> capture_outcome()
  end)
end
```

Add new private function `capture_outcome/1` in PollWorker:

```elixir
defp capture_outcome(issue) do
  resolved_at = DateTime.utc_now()
  days_open = DateTime.diff(resolved_at, issue.inserted_at, :second) / 86400.0
  triage = GitHub.latest_triage(issue.id)

  {outcome, amend_commit_count} = classify_outcome(issue)

  GitHub.record_triage_outcome!(%{
    issue_id: issue.id,
    triage_id: triage && triage.id,
    outcome: outcome,
    resolved_at: resolved_at,
    days_open: days_open,
    amend_commit_count: amend_commit_count,
    shadow: false
  })

  :telemetry.execute(
    [:harness, :triage, :outcome_recorded],
    %{count: 1},
    %{outcome: outcome, issue_id: issue.id, repo: issue.repo}
  )

  issue
end

defp classify_outcome(%{auto_demoted: true}), do: {"demoted", nil}

defp classify_outcome(%{pr_number: pr_number, repo: repo} = issue)
     when not is_nil(pr_number) do
  case Client.get_pull_request(repo, pr_number) do
    {:ok, %{merged: true}} ->
      triage = GitHub.latest_triage(issue.id)

      if triage && triage.final_route == "plan" do
        {"plan_executed", nil}
      else
        count_amendments(repo, pr_number)
      end

    {:ok, _} ->
      {"pr_closed_unmerged", nil}

    {:error, reason} ->
      Logger.warning("outcome PR fetch failed for #{repo}##{issue.number}: #{inspect(reason)}")
      {"pr_closed_unmerged", nil}
  end
end

defp classify_outcome(_issue), do: {"issue_closed_no_action", nil}

defp count_amendments(repo, pr_number) do
  case Client.list_pull_request_commits(repo, pr_number) do
    {:ok, commits} ->
      non_harness = max(0, length(commits) - 1)

      if non_harness == 0 do
        {"merged_untouched", 0}
      else
        {"merged_amended", non_harness}
      end

    {:error, _} ->
      {"merged_amended", nil}
  end
end
```

Note: `capture_outcome/1` silently no-ops on a duplicate via `on_conflict: :nothing`, making it safe to call on re-polls.

---

### Step 9 — Tests

#### a. Schema tests — new file
**File (new):** `test/harness/github/triage_outcome_test.exs`

```elixir
defmodule Harness.GitHub.TriageOutcomeTest do
  use Harness.DataCase, async: false

  alias Harness.GitHub
  alias Harness.GitHub.TriageOutcome

  test "valid changeset inserts a row" do
    issue = issue_fixture()
    now = DateTime.utc_now()

    attrs = %{
      issue_id: issue.id,
      outcome: "merged_untouched",
      resolved_at: now,
      days_open: 2.5
    }

    assert {:ok, row} =
             %TriageOutcome{} |> TriageOutcome.changeset(attrs) |> Harness.Repo.insert()

    assert row.outcome == "merged_untouched"
    assert row.shadow == false
    assert row.amend_commit_count == nil
  end

  test "duplicate insert on same issue_id is ignored (on_conflict: :nothing)" do
    issue = issue_fixture()
    now = DateTime.utc_now()
    attrs = %{issue_id: issue.id, outcome: "issue_closed_no_action",
              resolved_at: now, days_open: 1.0}

    GitHub.record_triage_outcome!(attrs)
    GitHub.record_triage_outcome!(attrs)   # second call — should not raise

    assert Harness.Repo.aggregate(TriageOutcome, :count) == 1
  end

  test "invalid outcome string is rejected" do
    issue = issue_fixture()
    attrs = %{issue_id: issue.id, outcome: "not_real", resolved_at: DateTime.utc_now(),
              days_open: 1.0}

    assert {:error, cs} = %TriageOutcome{} |> TriageOutcome.changeset(attrs) |> Harness.Repo.insert()
    assert "is invalid" in errors_on(cs).outcome
  end
end
```

#### b. Client tests — extend `test/harness/github/client_test.exs`

Add two new tests following the `find_pull_request` style, using `Req.Test.stub/2`:

```elixir
test "get_pull_request returns state/merged/merge_commit_sha" do
  Req.Test.stub(__MODULE__, fn conn ->
    Req.Test.json(conn, %{
      "state" => "closed", "merged" => true, "merge_commit_sha" => "abc123"
    })
  end)

  assert {:ok, %{state: "closed", merged: true, merge_commit_sha: "abc123"}} =
           Client.get_pull_request("owner/repo", 42)
end

test "get_pull_request returns :not_found on 404" do
  Req.Test.stub(__MODULE__, fn conn ->
    conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
  end)

  assert {:error, :not_found} = Client.get_pull_request("owner/repo", 99)
end

test "list_pull_request_commits returns a list of commit objects" do
  Req.Test.stub(__MODULE__, fn conn ->
    Req.Test.json(conn, [%{"sha" => "a1"}, %{"sha" => "b2"}])
  end)

  assert {:ok, [%{"sha" => "a1"}, %{"sha" => "b2"}]} =
           Client.list_pull_request_commits("owner/repo", 42)
end
```

#### c. PollWorker tests — extend `test/harness/github/poll_worker_test.exs`

Add a new section that stubs the new PR endpoints and asserts outcome rows. Since the file already uses `async: false` and the `stub_issues/2` pattern, extend `stub_issues/2` or add a separate stub helper:

```elixir
# helper to stub all three endpoints: /user, /repos/.../issues, /repos/.../pulls/{n},
# /repos/.../pulls/{n}/commits
defp stub_with_pr(issues, pr_state, commits \\ []) do
  Req.Test.stub(__MODULE__, fn conn ->
    case conn.request_path do
      "/user" ->
        Req.Test.json(conn, %{"login" => "nyelbangash"})

      "/repos/" <> rest ->
        cond do
          String.contains?(rest, "/commits") ->
            Req.Test.json(conn, commits)

          String.contains?(rest, "/pulls/") ->
            Req.Test.json(conn, pr_state)

          true ->
            conn
            |> Plug.Conn.put_resp_header("etag", ~s(W/"tag-1"))
            |> Req.Test.json(issues)
        end
    end
  end)
end

test "closed issue with no PR records issue_closed_no_action" do
  stub_issues([gh_issue_payload(number: 20)])
  assert :ok = perform_job(PollWorker, %{})
  issue = GitHub.get_issue_by(@repo, 20)
  GitHub.transition!(issue, "plan_ready")

  stub_issues([])
  reset_poll_clock()
  assert :ok = perform_job(PollWorker, %{})

  issue = GitHub.get_issue_by(@repo, 20)
  assert issue.pipeline_state == "done"

  [outcome] = Harness.Repo.all(Harness.GitHub.TriageOutcome)
  assert outcome.outcome == "issue_closed_no_action"
  assert outcome.issue_id == issue.id
end

test "merged PR with single commit records merged_untouched" do
  stub_issues([gh_issue_payload(number: 21)])
  assert :ok = perform_job(PollWorker, %{})
  issue = GitHub.get_issue_by(@repo, 21)
  issue |> Harness.GitHub.Issue.changeset(%{pr_number: 55, pr_url: "..."}) |> Harness.Repo.update!()
  GitHub.transition!(issue, "pr_open")

  stub_with_pr(
    [],
    %{"state" => "closed", "merged" => true, "merge_commit_sha" => "abc"},
    [%{"sha" => "abc"}]
  )

  reset_poll_clock()
  assert :ok = perform_job(PollWorker, %{})

  [outcome] = Harness.Repo.all(Harness.GitHub.TriageOutcome)
  assert outcome.outcome == "merged_untouched"
  assert outcome.amend_commit_count == 0
end

test "merged PR with multiple commits records merged_amended" do
  stub_issues([gh_issue_payload(number: 22)])
  assert :ok = perform_job(PollWorker, %{})
  issue = GitHub.get_issue_by(@repo, 22)
  issue |> Harness.GitHub.Issue.changeset(%{pr_number: 56, pr_url: "..."}) |> Harness.Repo.update!()
  GitHub.transition!(issue, "pr_open")

  stub_with_pr(
    [],
    %{"state" => "closed", "merged" => true, "merge_commit_sha" => "abc"},
    [%{"sha" => "a"}, %{"sha" => "b"}, %{"sha" => "c"}]
  )

  reset_poll_clock()
  assert :ok = perform_job(PollWorker, %{})

  [outcome] = Harness.Repo.all(Harness.GitHub.TriageOutcome)
  assert outcome.outcome == "merged_amended"
  assert outcome.amend_commit_count == 2
end

test "re-poll does not create a second outcome row" do
  stub_issues([gh_issue_payload(number: 23)])
  assert :ok = perform_job(PollWorker, %{})
  issue = GitHub.get_issue_by(@repo, 23)
  GitHub.transition!(issue, "plan_ready")

  stub_issues([])
  reset_poll_clock()
  assert :ok = perform_job(PollWorker, %{})

  stub_issues([])
  reset_poll_clock()
  assert :ok = perform_job(PollWorker, %{})

  assert Harness.Repo.aggregate(Harness.GitHub.TriageOutcome, :count) == 1
end

test "auto-demoted issue records demoted outcome" do
  stub_issues([gh_issue_payload(number: 24)])
  assert :ok = perform_job(PollWorker, %{})
  issue = GitHub.get_issue_by(@repo, 24)
  issue |> Harness.GitHub.Issue.changeset(%{auto_demoted: true}) |> Harness.Repo.update!()
  GitHub.transition!(issue, "triaged")

  stub_issues([])
  reset_poll_clock()
  assert :ok = perform_job(PollWorker, %{})

  [outcome] = Harness.Repo.all(Harness.GitHub.TriageOutcome)
  assert outcome.outcome == "demoted"
end
```

---

## Alternatives considered

**Alternative: detect `demoted` by querying triage history rather than adding a column**

Query: find issues whose most recent triage has `final_route == "auto"` but which are now in `triaged` state (post-demote). Rejected because a re-triage after demotion (triggered when the issue is updated upstream) would overwrite the auto-route triage with a new plan-route record, making the signal disappear. A boolean column on the issue is durable across re-triages.

**Alternative: use `run_events` table for the telemetry signal**

`run_events` has a non-null `run_id` FK, so outcome events that have no directly associated run (e.g., `issue_closed_no_action`) cannot be stored there without inventing a synthetic run. Using `:telemetry.execute/3` instead keeps the outcome capture decoupled from the run machinery and is standard in the Phoenix/Elixir ecosystem for metrics and dashboard charting.

**Alternative: poll PR state eagerly during `handle_issue/2` for `pr_open` issues**

The poller could call `get_pull_request` on every poll tick for every `pr_open` issue. Rejected for poll-cost reasons — this would make every poll cycle proportionally expensive for accumulated `pr_open` issues and clashes with the ETag caching philosophy of the existing poller. Capture at `reconcile_closed` is sufficient: issues close when PRs are merged (GitHub auto-close via "Closes #N"), making the reconcile hook the natural trigger.

## Open questions

1. **Demoted detection design — confirmation needed before implementation.** The plan above adds `auto_demoted: boolean` to the `issues` table. This is the recommended approach and resolves the gap, but it adds a column to a core table. An implementer should confirm this is preferred over annotating the triage decision row itself (e.g., adding `demoted_at` to `triages`).

2. **`plan_executed` attribution gap.** Currently only the auto lane writes `pr_number` to the issue record. Human-opened PRs in the plan lane will never be associated with the issue, so plan-lane issues closed by a human (the primary use case for `plan_executed`) will be recorded as `issue_closed_no_action`. The current design accepts this limitation for the initial capture phase. If full plan-lane attribution is required before the first analysis cycle, an additional mechanism to record the PR on plan-lane issues is needed — but that is a separate issue from capture.

3. **Commit attribution heuristic.** The plan assumes the harness always makes exactly one commit per PR (via `Repos.publish_branch!`). `amend_commit_count = total_commits - 1`. If there is a scenario where the harness makes multiple commits (e.g., force-push with history), this heuristic would over-count non-harness commits. Confirm the one-commit invariant holds.
