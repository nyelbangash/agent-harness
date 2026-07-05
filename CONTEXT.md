# Context: Ideation view: teaching empty state + seed composer with window awareness (#13)

## Relevant files

| File | Lines | Why it matters |
|------|-------|----------------|
| `harness/lib/harness_web/live/ideation_live.ex` | 1–280 | Primary target: all three changes (empty state, composer, window note) live here |
| `harness/lib/harness/policy.ex` | 86–143 | `gate_action(:ideate, ...)` and `seconds_until_window/2` are the computation this UI needs to surface; `window_note/1` is added here |
| `harness/lib/harness/policy/schema.ex` | 11–57 | `Models` struct (ideate/critique fields), `Ideate` struct (`default_budget_minutes`), `Schedule` struct (`ideation_windows`) — all read in the new mount |
| `harness/test/harness_web/live/ideation_live_test.exs` | 1–68 | Existing LV tests; the new clock-injection tests extend this file |
| `harness/test/support/fixtures/policy.yaml` | 9–12, 34–36 | Test fixture supplies `ideation_windows: ["21:00-02:00"]` and `default_budget_minutes: 180`; drives the frozen-clock test assertions |
| `harness/lib/harness_web/live/rail_hooks.ex` | 12–83 | `on_mount :default` assigns `mode`, `usage_mode`, `usage_health`; handles `:policy_reloaded` with `{:cont, ...}` so IdeationLive's own `handle_info` also fires |
| `harness/lib/harness/policy.ex` | 115–128 | `in_windows?/2` — called inside the new `window_note/1` helper |
| `harness/lib/harness/policy.ex` | 130–143 | `seconds_until_window/2` — the core arithmetic consumed by `window_note/1` |
| `harness/lib/harness/policy.ex` | 147–149 | `local_time/0` (private) — remains private; LiveViews compute `now` inline via `NaiveDateTime.local_now/0` |

---

## Related PRs and issues

- **Commit `338531d`** ("Phase 3: ideation engine — idea tree, iteration/critique/synthesis workers, tree UI") — introduced `IdeationLive`, `IterationWorker`, `CritiqueWorker`, and the `Ideation` context. The current bare composer form and the `sessions == []` empty state were both landed in this commit.
- **Commit `4ccc0cb`** ("Phase 2+3 hardening") — adversarial review pass on Phase 3 code; no UI changes to ideation.
- **Commit `6d54256`** ("Runs view: queue strip with slot occupancy and waiting depth") — most recent commit; adds the queue strip to `RunsLive`, a useful reference for the slot-occupancy display pattern (`:for` + conditional class on active slots).
- No prior issue references to #13 found in git log.

---

## Prior art in this codebase

**1. `Policy.gate/2` keyword injection pattern (`policy.ex:52–64`)**
The entire `gate/2` function accepts `policy:`, `usage_mode:`, and `now:` keyword overrides so
tests can freeze inputs without global mocking. The new `window_note/1` must follow the same
signature: `window_note(opts \\ [])` with `policy:` and `now:` kwargs. Tests in `policy_test.exs`
(lines 23–88) are the model.

**2. `connect_params` for LiveView test injection**
Phoenix LiveView exposes `get_connect_params/1` in `mount/3`. The connected render in tests
fires with whatever params are passed as the third argument to `live/3`. This is the right
vehicle for injecting `test_now` without global state; no other LiveView in this project
currently uses it, but it is a standard Phoenix mechanism.

**3. Conditional empty-state divs with `:if`**
Every LiveView in the project uses inline `:if` guards on `<div>` or `<p>` elements for
empty state, not separate render functions or LiveComponents. See `runs_live.ex:154` ("No
sessions yet."), `overview_live.ex:198` ("No runs yet —..."), and `ideation_live.ex:140`
(current "No sessions yet" copy). New empty-state markup should follow this pattern.

**4. Inline SVG in the template (`ideation_live.ex:191–235`)**
The idea tree is rendered as a raw `<svg>` block inside the template with `viewBox` set
dynamically. Static decorative diagrams (the loop diagram) use the same inline approach
rather than a LiveComponent or an `<img>` tag.

**5. Policy assigns flow through `RailHooks` (`rail_hooks.ex:12–83`)**
All LiveViews get `mode`, `usage_mode`, `usage_health` via the `on_mount :default` hook. The
`:policy_reloaded` message is handled by rail_hooks first (`{:cont, ...}`) and then passed
to the LiveView's own `handle_info`. IdeationLive must add its own clause for
`{:policy_reloaded, _}` to refresh `policy` and `window_note` assigns.

**6. `phx-change` on forms for live state (`budget_live.ex`)**
`BudgetLive` uses `phx-change` on its policy-editing form to re-render derived values without
a submit. The budget slider's live display update follows the same pattern.

**7. Score-color ramp with CSS variables (`ideation_live.ex:272–275`)**
Color is expressed as `var(--color-accent)`, `var(--color-ok)`, `var(--color-surface-2)` etc.
The loop diagram SVG nodes must use the same token set — not hardcoded hex — so the diagram
respects any future theme changes.

---

## External docs

**Phoenix LiveView — `get_connect_params/1`**
Available in `mount/3`; returns a map of params passed from the client on connect, or `nil`
in the disconnected phase. In `live/3` tests, pass via the third positional arg
`live(conn, path, connect_params: %{"key" => "val"})`. Relevant docs section: "Connect params
and connect info" in the LiveView guides.

**Phoenix LiveView — `phx-change` form events**
A `phx-change="event_name"` attribute on a `<form>` fires on every input change with the full
form params map. In the handler, params follow the same shape as `phx-submit`. Relevant
because the budget slider needs a live value display without a page reload.

**Elixir `Time.add/3`**
`Time.add(time, amount, unit)` where `unit` is `:second`, `:millisecond`, etc. Available since
Elixir 1.10. Wraps correctly past midnight (e.g., `Time.add(~T[23:30:00], 3600, :second)` →
`~T[00:30:00]`). This is the function used inside `window_note/1` to compute the next window
opening time from `now + seconds_until_window`.

**Elixir `Calendar.strftime/2`**
`Calendar.strftime(datetime_or_time, format_string)` — available since Elixir 1.11. `%H:%M`
produces zero-padded 24-hour HH:MM, matching the format users expect for the "will start at
HH:MM" display. No external dependency.

**SVG `<marker>` / `<defs>` for arrowheads**
The arrowhead on the loop diagram's connecting lines uses a standard SVG `<marker>` element
defined in `<defs>` and referenced via `marker-end="url(#arr)"`. This is pure SVG, no JS or
library required. Note that `marker-end` URLs are relative to the document; inline SVG in
an HTML page works correctly with `url(#id)` references.
