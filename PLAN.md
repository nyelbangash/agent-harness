# Plan: Ideation view: teaching empty state + seed composer with window awareness (#13)

## Problem restatement

`IdeationLive` renders a functional session UI once a session exists (SVG tree, node
inspector, journal strip), but a fresh deployment shows only a bare textarea with no
explanation of what will happen, how long it takes, or which models are involved. Two
specific gaps:

1. **Empty state** — when `sessions == []`, the sidebar shows "No sessions yet" (13 chars)
   and the main pane says "Select a session to watch its idea tree grow." Neither
   communicates the diverge → develop → critique → synthesize loop, typical cost
   expectations, or how to start.
2. **Composer ignorance** — the budget field is a plain number input hardcoded to 180,
   not a slider with a readable range, and the models used are invisible. More critically,
   submitting outside `schedule.ideation_windows` silently queues the session with no
   indication of when it will actually start; `Policy.gate/2` already computes
   `seconds_until_window` on the `:ideate` path (policy.ex:98) but the UI never calls it.

Expected behavior: first-time operators immediately understand the loop, the default
budget reads from policy, the composer names the models, and "will start at HH:MM" (or
"starts immediately") appears next to the Start button at all times.

---

## Implementation plan

### Step 1 — Add `Policy.window_note/1`

**File:** `harness/lib/harness/policy.ex`

Add a public function after `seconds_until_window/2` (after line 143):

```elixir
@doc """
Human-readable window status for the ideation composer.
Returns "starts immediately" when inside a window (or no windows configured),
otherwise "will start at HH:MM" for the next opening.
Accepts `policy:` and `now:` keyword overrides for testability (same pattern
as `gate/2`).
"""
@spec window_note(keyword()) :: String.t()
def window_note(opts \\ []) do
  policy = Keyword.get(opts, :policy, get())
  now = Keyword.get_lazy(opts, :now, &local_time/0)
  windows = policy.schedule.ideation_windows

  if windows == [] or in_windows?(now, windows) do
    "starts immediately"
  else
    secs = seconds_until_window(now, windows)
    next_time = Time.add(now, secs, :second)
    Calendar.strftime(next_time, "will start at %H:%M")
  end
end
```

`local_time/0` remains private; the public API takes `now: Time.t()` for tests.

---

### Step 2 — Update `IdeationLive.mount/3`

**File:** `harness/lib/harness_web/live/ideation_live.ex`

Replace the current `mount/3` (lines 14–23) with:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket), do: Ideation.subscribe()

  policy = Policy.get()
  # Tests inject "test_now" via connect_params ("HH:MM" string) to freeze the clock.
  now = parse_connect_now(get_connect_params(socket))
  budget = policy.ideate.default_budget_minutes

  {:ok,
   socket
   |> assign(:page_title, "Ideation")
   |> assign(:sessions, Ideation.list_sessions())
   |> assign(:selected_node, nil)
   |> assign(:policy, policy)
   |> assign(:window_note, Policy.window_note(policy: policy, now: now))
   |> assign(:budget_minutes, budget)
   |> assign(:form, to_form(%{"seed_prompt" => "", "budget_minutes" => "#{budget}"}))}
end
```

Add private helper (below `parse_int/2`):

```elixir
defp parse_connect_now(nil), do: NaiveDateTime.local_now() |> NaiveDateTime.to_time()
defp parse_connect_now(params) do
  case params["test_now"] do
    nil -> NaiveDateTime.local_now() |> NaiveDateTime.to_time()
    hhmm ->
      case Time.from_iso8601(hhmm <> ":00") do
        {:ok, t} -> t
        _ -> NaiveDateTime.local_now() |> NaiveDateTime.to_time()
      end
  end
end
```

Add `alias Harness.Policy` at the top of the alias block (currently only `Ideation` and
`Layout` are aliased; add `Policy`).

---

### Step 3 — Add new `handle_event` and `handle_info` clauses

**File:** `harness/lib/harness_web/live/ideation_live.ex`

**New `handle_event` — fill seed from a sample chip:**
```elixir
def handle_event("fill_seed", %{"seed" => seed}, socket) do
  form = to_form(%{
    "seed_prompt" => seed,
    "budget_minutes" => to_string(socket.assigns.budget_minutes)
  })
  {:noreply, assign(socket, :form, form)}
end
```

**New `handle_event` — live budget display update:**
```elixir
def handle_event("form_change", params, socket) do
  budget = parse_int(params["budget_minutes"], socket.assigns.budget_minutes)
  {:noreply, assign(socket, :budget_minutes, budget)}
end
```

**New `handle_info` — policy reload re-computes window note:**

In the existing `handle_info` block (after line 90), add before the catch-all:
```elixir
def handle_info({:policy_reloaded, _}, socket) do
  policy = Policy.get()
  now = NaiveDateTime.local_now() |> NaiveDateTime.to_time()
  {:noreply, socket |> assign(:policy, policy) |> assign(:window_note, Policy.window_note(policy: policy, now: now))}
end
```

Note: `RailHooks` handles `:policy_reloaded` first (returns `{:cont, ...}`) then passes
through to the LiveView's own `handle_info`, so this clause will fire after the rail
already updated `mode`, `usage_mode`, `usage_health`.

---

### Step 4 — Rewrite the `render/1` function

**File:** `harness/lib/harness_web/live/ideation_live.ex`

**4a. Composer form (left aside) — three changes:**

1. Add `phx-change="form_change"` to the `<form>` tag.

2. Replace the budget `<input type="number">` section with a slider + live display:
   ```heex
   <div class="flex items-center gap-2">
     <label class="font-mono text-[11px] text-ink-dim">budget</label>
     <input
       type="range"
       name="budget_minutes"
       value={@budget_minutes}
       min="30"
       max="360"
       step="30"
       class="flex-1 accent-accent"
     />
     <span class="font-mono text-[11px] text-ink-dim tabular-nums w-14 text-right">
       {@budget_minutes} min
     </span>
     <button class="font-display uppercase text-[10px] tracking-widest px-3 py-1.5 bg-accent text-bg rounded-sm">
       Start
     </button>
   </div>
   ```

3. Add models note + window note below the budget row:
   ```heex
   <div class="font-mono text-[10px] text-ink-dim/70 mt-1 space-y-0.5">
     <div>ideate: {@policy.models.ideate} · critique: {@policy.models.critique}</div>
     <div class={if String.starts_with?(@window_note, "starts"), do: "text-ok", else: "text-accent"}>
       {@window_note}
     </div>
   </div>
   ```

**4b. Main pane empty state (right section) — replace the minimal placeholder:**

Replace (lines 165–168):
```heex
<div :if={!@session} class="font-body text-sm text-ink-dim">
  Select a session to watch its idea tree grow.
</div>
```

With:
```heex
<div :if={!@session} class="space-y-8 py-4">
  <%# Loop diagram %>
  <div>
    <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-3">
      How ideation works
    </h2>
    <svg viewBox="0 0 320 80" class="w-full max-w-sm" aria-label="Ideation loop: diverge, develop, critique, synthesize">
      <%# Arrows %>
      <line x1="46" y1="40" x2="74" y2="40" stroke="var(--color-surface-2)" stroke-width="1.5" marker-end="url(#arr)" />
      <line x1="126" y1="40" x2="154" y2="40" stroke="var(--color-surface-2)" stroke-width="1.5" marker-end="url(#arr)" />
      <line x1="206" y1="40" x2="234" y2="40" stroke="var(--color-surface-2)" stroke-width="1.5" marker-end="url(#arr)" />
      <defs>
        <marker id="arr" markerWidth="6" markerHeight="6" refX="5" refY="3" orient="auto">
          <path d="M0,0 L6,3 L0,6 Z" fill="var(--color-surface-2)" />
        </marker>
      </defs>
      <%# Nodes %>
      <circle cx="30" cy="40" r="14" fill="var(--color-surface)" stroke="var(--color-accent)" stroke-width="1.5" />
      <circle cx="110" cy="40" r="14" fill="var(--color-surface)" stroke="var(--color-surface-2)" stroke-width="1.5" />
      <circle cx="190" cy="40" r="14" fill="var(--color-surface)" stroke="var(--color-surface-2)" stroke-width="1.5" />
      <circle cx="270" cy="40" r="14" fill="var(--color-surface)" stroke="var(--color-ok)" stroke-width="1.5" />
      <%# Labels %>
      <text x="30" y="64" text-anchor="middle" font-size="8" fill="var(--color-ink-dim)" class="font-mono">diverge</text>
      <text x="110" y="64" text-anchor="middle" font-size="8" fill="var(--color-ink-dim)" class="font-mono">develop</text>
      <text x="190" y="64" text-anchor="middle" font-size="8" fill="var(--color-ink-dim)" class="font-mono">critique</text>
      <text x="270" y="64" text-anchor="middle" font-size="8" fill="var(--color-ink-dim)" class="font-mono">synthesize</text>
    </svg>
    <p class="font-body text-[12px] text-ink-dim mt-2 max-w-sm">
      Each iteration branches the top-scoring frontier nodes, then a critique trims the weak ones. After {@policy.ideate.default_budget_minutes} min the tree collapses to SYNTHESIS.md.
    </p>
  </div>

  <%# Sample seeds %>
  <div>
    <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-2">
      Try a sample idea
    </h2>
    <div class="flex flex-wrap gap-2">
      <button
        :for={seed <- sample_seeds()}
        type="button"
        phx-click="fill_seed"
        phx-value-seed={seed}
        class="font-body text-[12px] text-ink border border-surface-2 rounded-sm px-2.5 py-1.5 hover:bg-surface hover:border-accent text-left"
      >
        {seed}
      </button>
    </div>
  </div>
</div>
```

Add private function for sample seeds (after `session_status_class/1`):
```elixir
defp sample_seeds do
  [
    "A smarter PR triage that learns from past false positives",
    "Daily cost summaries pushed to mobile when the budget crosses 50%",
    "Adaptive ideation windows that shift based on rolling utilization"
  ]
end
```

(Exact seed text subject to author sign-off — see Open Questions.)

---

### Step 5 — Tests

**File:** `harness/test/harness_web/live/ideation_live_test.exs`

**5a. Expand the existing empty-state test** to cover the new diagram and sample chips:
```elixir
test "empty state shows the loop diagram and sample seeds", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/ideation")
  assert html =~ "How ideation works"
  assert html =~ "diverge"
  assert html =~ "synthesize"
  assert html =~ "Try a sample idea"
  # at least one sample seed is present
  assert html =~ "false positives"
end
```

(Keep the original test or merge it in; either way the "No sessions yet" text is gone,
so update the old assertion to match the new copy.)

**5b. New test — sample seed click fills the textarea:**
```elixir
test "clicking a sample seed prefills the seed form", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/ideation")
  html = view |> element("button[phx-click='fill_seed']") |> render_click()
  assert html =~ "false positives"  # or whichever seed renders first
end
```

**5c. New test — window note shows "starts immediately" inside the window:**
```elixir
test "composer shows 'starts immediately' inside ideation window", %{conn: conn} do
  # 22:00 is inside the fixture policy's 21:00-02:00 ideation window
  {:ok, _view, html} = live(conn, ~p"/ideation", connect_params: %{"test_now" => "22:00"})
  assert html =~ "starts immediately"
end
```

**5d. New test — window note shows computed start time outside the window:**
```elixir
test "composer shows start time when outside ideation window", %{conn: conn} do
  # 12:00 is outside 21:00-02:00; next window opens at 21:00 (9 h away)
  {:ok, _view, html} = live(conn, ~p"/ideation", connect_params: %{"test_now" => "12:00"})
  assert html =~ "will start at 21:00"
end
```

These tests use `connect_params` (accessible via `get_connect_params/1` in `mount/3`)
to freeze the clock without global state or mocking. This follows the existing
`policy: p, now: t` injection pattern used in `policy_test.exs`.

---

### File summary

| File | Change |
|------|--------|
| `harness/lib/harness/policy.ex` | Add public `window_note/1` |
| `harness/lib/harness_web/live/ideation_live.ex` | Update mount/3, add aliases, add handle\_event/handle\_info clauses, update render |
| `harness/test/harness_web/live/ideation_live_test.exs` | Update existing test, add 3 new tests |

No new files. No database migrations. No router changes.

---

## Alternatives considered

**A. Dedicated LiveComponent for the loop diagram**
Extracting the SVG into a `HarnessWeb.Components.IdeationLoop` component adds indirection
for a diagram that appears exactly once and will likely never be reused. Inline SVG in the
template is simpler and consistent with how the tree SVG is inlined in the same module.

**B. JS hook for budget slider live value**
A `phx-hook` could update the label client-side without a server round-trip. However, it
adds a JS module and a hook registration for a minor UX improvement. The `phx-change` on
the form already fires cheaply (no DB work), and the existing codebase has no registered
JS hooks, so keeping it server-side avoids introducing a new pattern.

**C. Accept `now` via URL param instead of `connect_params`**
URL params would pollute routes and expose internal test machinery in browser URLs.
`connect_params` are a dedicated LiveView mechanism for mount-time metadata that don't
appear in URLs and are not user-navigable.

**D. Make `window_note` a private LiveView helper**
Keeping it private to `IdeationLive` would work, but it's a policy-domain computation
that already lives near `seconds_until_window/2` and `in_windows?/2`. Placing it in
`Policy` makes it directly unit-testable and keeps all window logic co-located.

---

## Open questions

1. **Sample seed copy** — the three seeds proposed are placeholders that reflect the
   system's domain. The triage note flags these as requiring author sign-off before an
   implementing agent commits them. Please confirm or replace before the agent writes code.

2. **SVG loop diagram aesthetics** — the plan specifies a compact 320×80 viewBox with
   four circles and arrowhead markers. If you want a different shape (rectangles, a
   circular loop layout, icons per phase), specify before implementation. The agent will
   otherwise build the horizontal 4-circle layout described.

3. **Budget slider step** — the issue says 30–360 min but is silent on granularity. The
   plan uses `step="30"` for clean half-hour increments. Use `step="10"` if finer control
   is preferred.

4. **Window note on `rail_tick`** — `RailHooks` sends `:rail_tick` every 60 s for
   liveness, but that event only refreshes `mode`/`usage_mode`/`usage_health`. Should
   `IdeationLive` also update `window_note` on each tick? This matters near window
   boundaries (e.g., 21:00 arrives and the note should flip to "starts immediately"). The
   plan as written only recomputes on `{:policy_reloaded, _}`. Recommend adding a
   `:rail_tick` handler to keep the note fresh; flagging for author confirmation.
