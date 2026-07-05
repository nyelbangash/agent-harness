# Plan: Promote-to-epic: scaffold GitHub issues from a synthesized ideation branch (#5)

## Problem restatement

A completed ideation session ends in a synthesis artifact and a scored idea tree. When a branch looks promising, turning it into actionable pipeline work currently requires manual GitHub issue creation. The request is to add a one-click promotion path: the operator selects a node in the IdeationLive tree, chooses a target repo from policy, and the harness scaffolds an epic issue plus N child issues (each sized and worded to score well in triage), all self-assigned so `PollWorker` picks them up on the next sweep.

Expected behavior: click "Promote" on a synthesized/high-scoring node → confirm modal with target-repo select → PromoteWorker enqueued → model call builds the issue set → epic + children appear on GitHub → epic URL visible in the node panel.

Actual behavior: no such path exists. Promoting a branch is entirely manual.

## Implementation plan

### Step 1 — Resolve provenance dependency

The `Harness.GitHub.Provenance` module exists only on branch `harness/issue-1-provenance-marker-on-all-harness-authore` (commit `ed62b8c`), not on master.

**Option A (preferred)**: merge that branch first, then implement this issue.

**Option B** (if unmerged): create `harness/lib/harness/github/provenance.ex` as part of this work. The full module is 28 lines; its `stamp(body, kind, ref)`, `harness_authored?(body)`, and `parse(body)` functions are simple string operations. The marker format is `<!-- harness:v1 kind=K ref=R -->`.

Every harness-authored body passed to GitHub in subsequent steps must be stamped with `Provenance.stamp(body, "promote", ref)` where `ref` is `"ideation:session-#{session_id}/idea-#{idea_id}"`.

---

### Step 2 — GitHub Client: `create_issue/4` and `update_issue/3`

**File: `harness/lib/harness/github/client.ex`**

Add two public functions after `post_issue_comment/3` (current line 61):

```elixir
@doc "Create an issue. Returns `{:ok, %{number: n, url: html_url}}`."
def create_issue(repo, title, body, opts \\ []) do
  payload =
    %{title: title, body: body}
    |> maybe_put(:assignees, Keyword.get(opts, :assignees))
    |> maybe_put(:labels, Keyword.get(opts, :labels))

  case request(:post, "/repos/#{repo}/issues", json: payload) do
    {:ok, %{status: 201, body: %{"number" => n, "html_url" => url}}} ->
      {:ok, %{number: n, url: url}}
    {:ok, %{status: status}} ->
      {:error, {:http_status, status}}
    {:error, reason} ->
      {:error, reason}
  end
end

@doc "Update an issue (PATCH). `attrs` may include `:body`, `:title`, etc."
def update_issue(repo, number, attrs) do
  case request(:patch, "/repos/#{repo}/issues/#{number}", json: attrs) do
    {:ok, %{status: 200}} -> :ok
    {:ok, %{status: status}} -> {:error, {:http_status, status}}
    {:error, reason} -> {:error, reason}
  end
end
```

Add private helper `maybe_put(map, _key, nil)` → `map` and `maybe_put(map, key, val)` → `Map.put(map, key, val)` (or inline with `if` guards).

No changes to `request/3` — it already supports `:patch` via `method: method`.

**Test additions to `harness/test/harness/github/client_test.exs`**:
- `create_issue/4` happy path: stub returns 201 with `%{"number" => 42, "html_url" => "..."}`, assert `{:ok, %{number: 42}}`. Verify `authorization` and `x-github-api-version` headers, method is POST, body has title/body/assignees.
- `update_issue/3` happy path: stub returns 200, assert `:ok`. Verify method is PATCH, path includes issue number.
- `create_issue/4` failure: stub returns 422, assert `{:error, {:http_status, 422}}`.

---

### Step 3 — DB migration: `ideation_promotions` table

**New file: `harness/priv/repo/migrations/20260704000012_create_ideation_promotions.exs`**

```elixir
defmodule Harness.Repo.Migrations.CreateIdeationPromotions do
  use Ecto.Migration

  def change do
    create table(:ideation_promotions) do
      add :idea_id,    references(:ideas, on_delete: :delete_all), null: false
      add :session_id, references(:ideation_sessions, on_delete: :delete_all), null: false
      add :run_id,     references(:runs, on_delete: :nilify_all)
      add :target_repo, :string, null: false
      add :epic_number, :integer
      add :epic_url,    :string
      add :status,     :string, null: false, default: "running"
      add :error_detail, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ideation_promotions, [:idea_id])
    create index(:ideation_promotions, [:session_id])
  end
end
```

`status` values: `"running" | "succeeded" | "failed"`.

---

### Step 4 — `Harness.Ideation.Promotion` schema

**New file: `harness/lib/harness/ideation/promotion.ex`**

Ecto schema wrapping `ideation_promotions`. Fields mirror the migration. Belongs to `Idea`, `Session`, and `Run` (nullable). Changeset validates `status` inclusion and required fields `idea_id`, `session_id`, `target_repo`.

---

### Step 5 — `Harness.Ideation` context additions

**File: `harness/lib/harness/ideation.ex`**

Add at the bottom of the module (new public functions):

```elixir
@doc "All descendants of a node (for promotion context)."
def subtree(%Idea{id: id, session_id: sid}) do
  all = tree(sid)
  descendants(all, id, [])
end

defp descendants(all, parent_id, acc) do
  children = Enum.filter(all, &(&1.parent_id == parent_id))
  Enum.reduce(children, acc ++ children, fn child, a ->
    descendants(all, child.id, a)
  end)
end

def create_promotion!(attrs) do
  %Promotion{}
  |> Promotion.changeset(attrs)
  |> Repo.insert!()
end

def update_promotion!(%Promotion{} = p, attrs) do
  p |> Promotion.changeset(attrs) |> Repo.update!()
end

def latest_promotion(idea_id) do
  from(p in Promotion,
    where: p.idea_id == ^idea_id,
    order_by: [desc: p.id],
    limit: 1
  )
  |> Repo.one()
end
```

Add `alias Harness.Ideation.Promotion` at the top with the other aliases.

---

### Step 6 — `RunSpec` kind: add `:promote`

**File: `harness/lib/harness/runs/run_spec.ex`** (line 28)

Change:
```elixir
kind: :triage | :implement | :plan | :ideate | :critique,
```
to:
```elixir
kind: :triage | :implement | :plan | :ideate | :critique | :promote,
```

No runtime impact — the kind is used only for run record labeling.

---

### Step 7 — `Harness.Prompts.promote/4`

**File: `harness/lib/harness/prompts.ex`**

Add after `synthesis/1` (current line ~83):

```elixir
def promote(session, idea, ancestors, subtree) do
  render("promote_epic.md.eex",
    seed_prompt: session.seed_prompt,
    node_title: idea.title,
    node_summary: idea.summary || "",
    node_score: idea.score,
    ancestor_chain: format_ancestors_for_promote(ancestors),
    subtree_outline: format_subtree(subtree),
    artifact: truncate(read_artifact(idea) || "(no artifact)", 8_000),
    subtree_artifacts: format_subtree_artifacts(subtree)
  )
end
```

Add private helpers:
- `format_ancestors_for_promote(nodes)`: same as `format_ancestors/1` — indented `- Title: Summary` lines.
- `format_subtree(nodes)`: `"#{n.id} · d#{n.depth} · #{n.status} · #{n.score} · #{n.title}"` per line (reuse `format_tree` shape but scoped to subtree).
- `format_subtree_artifacts(nodes)`: for each node in subtree with a non-nil artifact_path, emit `"### #{n.title}\n\n#{truncate(artifact, 2_000)}\n"`. Cap at the first 5 nodes with artifacts to avoid prompt bloat.

---

### Step 8 — Prompt template: `ops/prompts/promote_epic.md.eex`

**New file: `ops/prompts/promote_epic.md.eex`**

Structure (write the actual EEx template):

```
You are promoting a branch of an ideation session into a GitHub issue epic.
Your output will be used verbatim to create GitHub issues, so write for a
developer audience, not for the model. Be precise and grounded.

## Session seed (verbatim)
<%= @seed_prompt %>

## The node being promoted
Title: <%= @node_title %>
Score: <%= @node_score %>
Summary: <%= @node_summary %>

## Ancestor context (root → parent)
<%= @ancestor_chain %>

## Full artifact for this node
<%= @artifact %>

## Subtree (descendants already explored)
<%= @subtree_outline %>

## Subtree artifacts (selected)
<%= @subtree_artifacts %>

## Your task
Produce one epic issue and 2–6 child issues. The children must be sized and
written so the harness triage scores them "auto": xs or s scope, one crisp
self-contained change per issue, no underspecification.

**For each child issue body, include ALL of the following:**
- **What to change**: exact file paths and function/module names where possible
  (a triage reader should be able to `grep` for the location)
- **Why**: the motivation in one or two sentences
- **Acceptance criteria**: a short checklist of observable behaviors (tests,
  outputs, or API responses) that prove the change is correct
- **Non-goals**: one or two things explicitly out of scope for this issue
- **Rough size**: xs (single file, < ~20 lines) or s (one–two files, < ~50 lines)

The epic body should: describe the overall capability the branch is building,
link the synthesis/ideation context, enumerate children as a task list
(the pipeline will fill in the actual links after creating them), and note
any blocking ordering between children.

Output ONLY the JSON object matching the schema. No prose outside the JSON.
```

---

### Step 9 — `Harness.Ideation.PromoteWorker`

**New file: `harness/lib/harness/ideation/promote_worker.ex`**

```elixir
use Oban.Worker,
  queue: :implement,          # concurrency 1, serializes sequential GitHub writes
  max_attempts: 1,            # explicit human action — no auto-retry (creates dup issues)
  unique: [keys: [:idea_id, :target_repo], states: :incomplete, period: :infinity]
```

**JSON schema module attribute** (inline `Jason.encode!`, like `CritiqueWorker`):
```elixir
@promote_schema Jason.encode!(%{
  type: "object",
  properties: %{
    epic: %{
      type: "object",
      properties: %{title: %{type: "string"}, body: %{type: "string"}},
      required: ["title", "body"], additionalProperties: false
    },
    children: %{
      type: "array", minItems: 1,
      items: %{
        type: "object",
        properties: %{title: %{type: "string"}, body: %{type: "string"}},
        required: ["title", "body"], additionalProperties: false
      }
    }
  },
  required: ["epic", "children"],
  additionalProperties: false
})
```

**`perform/1` flow** (`%Oban.Job{args: %{"session_id" => sid, "idea_id" => iid, "target_repo" => repo}}`):

```
1.  Load session = Ideation.get_session!(sid), idea = Ideation.get_idea!(iid)
2.  policy = Policy.get()
3.  Guard: policy.mode == :paused → {:cancel, :paused}
4.  Guard: repo not in Enum.map(policy.github.repos, & &1.name) → {:cancel, :repo_not_in_policy}
5.  viewer_login = resolve_login()   # cached :persistent_term like PollWorker
6.  ancestors = Ideation.ancestor_chain(idea)
7.  subtree   = Ideation.subtree(idea)
8.  prompt    = Harness.Prompts.promote(session, idea, ancestors, subtree)
9.  promotion = Ideation.create_promotion!(%{
      idea_id: idea.id, session_id: session.id, target_repo: repo, status: "running"
    })
10. ref = "ideation:session-#{session.id}/idea-#{idea.id}"
11. spec = %RunSpec{
      kind: :promote, model: policy.models.plan, prompt: prompt,
      cwd: Ideation.session_dir(session), output_mode: :json,
      json_schema: @promote_schema, allowed_tools: ["Read"],
      max_turns: 15, ref: ref,
      timeout_ms: :timer.minutes(10)
    }
12. Run: case Runs.execute(spec) do
      {:ok, result} → proceed to contract validation
      {:error, :killed} →
        Ideation.update_promotion!(promotion, %{status: "failed", error_detail: "killed"})
        {:cancel, :killed}
      {:error, reason} →
        Ideation.update_promotion!(promotion, %{status: "failed", error_detail: inspect(reason)})
        {:error, reason}
    end
13. Validate result.structured_output shape:
    - must have "epic" with "title" and "body"
    - must have "children" list with at least one item, each with "title" and "body"
    - If invalid: update promotion (failed), {:cancel, :invalid_contract}
14. Create epic issue:
    epic_body = Provenance.stamp(contract["epic"]["body"], "promote", ref)
    case Client.create_issue(repo, contract["epic"]["title"], epic_body,
                             assignees: [viewer_login]) do
      {:ok, %{number: n, url: url}} → epic_number = n, epic_url = url
      {:error, reason} →
        Ideation.update_promotion!(promotion, %{status: "failed", error_detail: "epic: #{inspect(reason)}"})
        {:error, {:epic_creation_failed, reason}}
    end
    # record run_id now that the epic exists
    Ideation.update_promotion!(promotion, %{run_id: result.run_id, epic_number: epic_number, epic_url: epic_url})
15. Create children (accumulate links for backfill):
    child_links = create_children(repo, contract["children"], epic_number, viewer_login, ref)
    (See partial-failure semantics below.)
16. Patch epic body with task list:
    task_list = Enum.map_join(child_links, "\n", fn {n, url, title} ->
      "- [ ] #{url} — #{title}"
    end)
    new_body = epic_body <> "\n\n## Child issues\n\n#{task_list}"
    Client.update_issue(repo, epic_number, %{body: new_body})
    # log but don't fail if the patch fails (non-critical)
17. Ideation.update_promotion!(promotion, %{status: "succeeded"})
18. broadcast on "ideation:#{session.id}": {:promotion_completed, promotion}
19. Harness.Notify.notify(:promotion_complete, "Epic created: #{epic_url}")
20. :ok
```

**Partial-failure in `create_children/5`**: iterate children in order. On success, append `{number, url, title}` to acc. On failure: `Client.post_issue_comment(repo, epic_number, "⚠️ Child creation stopped at ##{i+1}/#{total}: ...")`, return accumulated links (do NOT delete already-created children, do NOT abort the whole job with an error — the epic exists and is usable).

**`resolve_login/0`** private: same pattern as `PollWorker.assignee_login/0` — `:persistent_term.get/2` with `Client.viewer_login()` fallback.

---

### Step 10 — `IdeationLive` UI additions

**File: `harness/lib/harness_web/live/ideation_live.ex`**

**Assign additions in `mount/3`** (after line 22):
```elixir
|> assign(:promote_modal, nil)
|> assign(:policy_repos, Harness.Policy.get().github.repos |> Enum.map(& &1.name))
```

**New event handlers** (add alongside `handle_event("stop_session", ...)` at line 72):

```elixir
def handle_event("show_promote_modal", %{"id" => id}, socket) do
  idea = Ideation.get_idea!(String.to_integer(id))
  {:noreply, assign(socket, :promote_modal, %{idea: idea})}
end

def handle_event("cancel_promote", _params, socket) do
  {:noreply, assign(socket, :promote_modal, nil)}
end

def handle_event("promote", %{"target_repo" => repo}, socket) do
  modal = socket.assigns.promote_modal

  if repo in socket.assigns.policy_repos and modal do
    %{
      session_id: socket.assigns.session.id,
      idea_id: modal.idea.id,
      target_repo: repo
    }
    |> Harness.Ideation.PromoteWorker.new()
    |> Oban.insert()

    {:noreply,
     socket
     |> assign(:promote_modal, nil)
     |> put_flash(:info, "Promote queued — progress at /runs")}
  else
    {:noreply, put_flash(socket, :error, "Invalid target repo")}
  end
end
```

**`handle_info` addition** (add a new clause before the catchall at line 90):

```elixir
def handle_info({:promotion_completed, promotion}, socket) do
  socket =
    if socket.assigns[:selected_node] &&
         socket.assigns.selected_node.idea.id == promotion.idea_id do
      assign(socket, :selected_node, %{
        socket.assigns.selected_node
        | idea: Ideation.get_idea!(promotion.idea_id),
          promotion: promotion
      })
    else
      socket
    end

  {:noreply, socket}
end
```

Subscribe to session-scoped topic is already done via `Ideation.subscribe(id)` in `handle_params/3`.

**Template additions** in `render/1` (inside the `<div :if={@selected_node}>` block, after the artifact display at line ~253):

1. Promote button — show when session is `"synthesized"` and idea score >= 7.5 and no in-progress or succeeded promotion:

```heex
<button
  :if={@session && @session.status == "synthesized" &&
       @selected_node.idea.score >= 7.5 &&
       @policy_repos != []}
  phx-click="show_promote_modal"
  phx-value-id={@selected_node.idea.id}
  class="mt-3 font-display uppercase text-[10px] tracking-widest px-3 py-1.5 bg-accent text-bg rounded-sm"
>
  Promote to epic
</button>
```

2. Epic URL display (when promotion succeeded):

```heex
<a
  :if={Map.get(@selected_node, :promotion) && @selected_node.promotion.status == "succeeded"}
  href={@selected_node.promotion.epic_url}
  target="_blank"
  class="mt-2 block font-mono text-[11px] text-accent underline"
>
  Epic: {@selected_node.promotion.epic_url}
</a>
```

3. Promote modal (at the end of `render/1`, after the main grid, before `</Layouts.app>`):

```heex
<div
  :if={@promote_modal}
  class="fixed inset-0 bg-bg/80 flex items-center justify-center z-50"
>
  <div class="bg-surface border border-surface-2 rounded-sm p-6 w-80 space-y-4">
    <h2 class="font-display uppercase tracking-[0.14em] text-sm text-ink">
      Promote to epic
    </h2>
    <p class="font-body text-sm text-ink-dim">
      {@promote_modal.idea.title}
      (score {@promote_modal.idea.score})
    </p>
    <form phx-submit="promote" class="space-y-3">
      <select name="target_repo"
              class="w-full bg-surface border border-surface-2 rounded-sm px-2 py-1.5 font-mono text-sm text-ink">
        <option :for={repo <- @policy_repos} value={repo}>{repo}</option>
      </select>
      <div class="flex gap-2 justify-end">
        <button type="button" phx-click="cancel_promote"
                class="font-display uppercase text-[10px] tracking-widest px-3 py-1.5 border border-surface-2 text-ink-dim rounded-sm">
          Cancel
        </button>
        <button type="submit"
                class="font-display uppercase text-[10px] tracking-widest px-3 py-1.5 bg-accent text-bg rounded-sm">
          Confirm
        </button>
      </div>
    </form>
  </div>
</div>
```

**`load_session/2` addition**: load the latest promotion for the selected node. The current `load_session` doesn't need changing; the promotion is loaded lazily when `handle_info({:promotion_completed, ...})` fires, or on `select_node` by adding a `promotion: Ideation.latest_promotion(idea.id)` field to the `:selected_node` assign.

Modify `handle_event("select_node", ...)` at line 65:
```elixir
def handle_event("select_node", %{"id" => id}, socket) do
  idea = Ideation.get_idea!(String.to_integer(id))
  promotion = Ideation.latest_promotion(idea.id)

  {:noreply,
   assign(socket, :selected_node, %{
     idea: idea,
     artifact: Ideation.read_artifact(idea),
     promotion: promotion
   })}
end
```

---

### Step 11 — Test files

#### `harness/test/harness/github/client_test.exs` (additions)

Add to existing module:
- `create_issue/4` happy path, `create_issue/4` 422, `update_issue/3` happy path (pattern matches from existing `post_issue_comment` test at line 60).

#### `harness/test/harness/ideation/promote_worker_test.exs` (new)

```elixir
defmodule Harness.Ideation.PromoteWorkerTest do
  use Harness.DataCase, async: false
  alias Harness.Ideation
  alias Harness.Ideation.PromoteWorker
  alias Harness.Runs.FakeRunner
  @moduletag :capture_log
```

Tests to include:
1. **Happy path** — FakeRunner returns canned contract `{epic: {...}, children: [{...}, {...}]}`. Assert:
   - Epic issue created (Req.Test verifies POST /repos/.../issues, body contains title + provenance marker, assignees: [login]).
   - Two child issues created (each linking epic URL in body, provenance marker present).
   - Epic body patched with PATCH /repos/.../issues/N containing task list.
   - `ideation_promotions` record: status "succeeded", `epic_url` set.
   - Broadcast `{:promotion_completed, promotion}` on `"ideation:#{session_id}"`.
2. **Policy guard: non-policy repo** — `perform_job(PromoteWorker, %{..., target_repo: "not/there"})` → `{:cancel, :repo_not_in_policy}`. No Req calls made.
3. **Policy guard: paused mode** — swap policy mode to `:paused`, assert `{:cancel, :paused}`.
4. **Malformed contract** — FakeRunner returns `{:ok, runner_result(structured_output: %{"garbage" => 1})}`. Assert `{:cancel, :invalid_contract}`, promotion status "failed", no GitHub API calls for issue creation.
5. **Epic creation fails** — Req stub returns 422 on POST /issues. Assert `{:error, {:epic_creation_failed, _}}`, promotion status "failed", no child creation attempts.
6. **Child creation fails mid-way** — First child POST succeeds, second fails. Assert:
   - `Client.post_issue_comment` called on the epic (failure comment).
   - Only one child created.
   - Epic body patched with the one successful child link.
   - Promotion status "succeeded" (partial success with failure note is acceptable).
7. **Provenance marker assertion** — Req.Test captures POST body, asserts `body =~ "<!-- harness:v1 kind=promote"` for both epic and children.

#### `harness/test/harness_web/live/ideation_live_test.exs` (additions)

Add to existing module:
1. **Promote button not shown on running session** — start_session → mount → assert no "Promote to epic" text.
2. **Promote button shown on synthesized session with high-scoring node** — stop_session → synthesize → add node with score 9.0 → mount → select node → assert "Promote to epic" button.
3. **Promote button hidden when no policy repos** — synthesized session, policy repos empty → no button.
4. **Modal opens on promote click** — click "Promote to epic" → assert modal content and repo select.
5. **Confirm enqueues PromoteWorker** — fill select → submit → assert job enqueued (Oban test helpers), flash info.
6. **Epic URL displayed after promotion_completed broadcast** — select node → send `{:promotion_completed, promotion}` to view → assert epic URL link in HTML.

---

### Step 12 — Wire up broadcast in `Ideation`

**File: `harness/lib/harness/ideation.ex`**

`update_promotion!` should broadcast after update:
```elixir
def update_promotion!(%Promotion{} = p, attrs) do
  p = p |> Promotion.changeset(attrs) |> Repo.update!()
  if p.status == "succeeded" do
    broadcast(p.session_id, {:promotion_completed, p})
  end
  p
end
```

Alternatively, the broadcast can be done in `PromoteWorker` directly after the final update (step 18 in the flow above) — this is cleaner since the worker knows when "succeeded" is the final state. Choose the worker-side approach; `update_promotion!/2` stays a pure DB function.

---

### Ordering

1. Merge issue #1 (or create `provenance.ex`)
2. Steps 2 (client), 3 (migration), 4 (schema), 5 (context) — can be done in parallel
3. Steps 6–8 (run_spec, prompts, template) — no DB dependency
4. Step 9 (PromoteWorker) — depends on 2–8
5. Step 10 (IdeationLive) — depends on 5 and 9 (needs worker module for `new/1`)
6. Step 11 (tests) — depends on all of the above

## Alternatives considered

### Alternative A: Store epic URL on the `ideas` row instead of a separate `ideation_promotions` table

Adding `epic_url` and `epic_number` columns directly to `ideas` is simpler (one table, no join), but conflates the idea tree node with its promotion artifact. If a node is promoted to multiple repos, or promoted twice after a failed first attempt, this breaks. The `ideation_promotions` table is only a few extra lines and keeps concerns clean.

### Alternative B: Use `:stream_json` output mode (PlanWorker-style) instead of `:json` with schema

The issue says "plan-lane run machinery" which could be read as matching PlanWorker's `stream_json` approach (where the agent writes files). But there's no file artifact here — the model's output is the JSON contract directly. Using `:json` with `json_schema` matches the triage/critique/iteration worker pattern and gives the CLI-side schema enforcement plus Elixir-side validation. `stream_json` would require parsing unstructured output, which is more fragile for a precisely structured contract.

### Alternative C: Infer the viewer login per-promotion instead of caching in `:persistent_term`

Calling `Client.viewer_login()` on every promotion is one extra API round-trip. The `:persistent_term` caching pattern from `PollWorker` is already established and avoids this. No reason to diverge.

### Alternative D: Run PromoteWorker on the `:ideate` queue instead of `:implement`

`:ideate` (concurrency 1) would also serialize promotions, but it's semantically wrong — ideation sessions use that queue, and mixing promotions there could block an ongoing ideation sweep. `:implement` is already the queue for "sequential GitHub-heavy operations" (both PlanWorker and ImplementWorker ride it at concurrency 1).

## Open questions

1. **Provenance dependency**: Is issue #1 (`harness/issue-1-provenance-marker-on-all-harness-authore`) merged into master before this work begins? If not, the implementer must create `harness/lib/harness/github/provenance.ex` as a prerequisite (28 lines, low risk). **Needs human decision.**

2. **Model budget for promote**: No `promote_max_turns` exists in the `Policy.Schema.Budgets` struct. The plan hardcodes `max_turns: 15` (adequate for a single-pass structured output task). Should this be made configurable in policy.yaml, following the pattern of `triage_max_turns`, `plan_max_turns`? If so, add `promote_max_turns: 15` to `Budgets` defstruct and policy.yaml example. **Low-stakes — implementer can decide.**

3. **"Promote" button trigger condition**: The plan uses `session.status == "synthesized" and idea.score >= 7.5`. The issue says "synthesized/high-scoring nodes" without specifying the threshold. The 7.5 cutoff matches the existing `score_fill` accent color in the tree (line 273 of `ideation_live.ex`). If the intent is to allow promotion of any node in a finished session regardless of score, the condition can be relaxed to just `session.status in ["synthesized", "stopped"]`. **Needs human decision.**

4. **Partial child failure as "succeeded"**: The plan treats the promotion as succeeded even if some children failed (failure note posted on the epic). The issue says "on child failure, comment the failure on the epic rather than deleting" but doesn't specify the job return value in that case. If the preference is to mark the promotion `status: "failed"` when any child fails, the worker should be updated accordingly. **Needs human decision.**
