# Review: PR #4 — Update the calendar dashboard widgets for the screenful lattice

Reviewed against `AGENTS.md`'s "Dashboard widgets" section and the duck-typed
`phoenix_kit_widgets/0` contract with the sibling `phoenix_kit_dashboards` package.
Scope: `lib/phoenix_kit_calendar.ex` (widget declarations), the three widget
LiveComponents, `Web.WidgetSupport`, and `test/phoenix_kit_calendar/web/widget_test.exs`,
as merged at `56c744c` (merge of PR #4, branch `mdon/main`), current tree at `497e251`.

Methodology: read every changed file with full surrounding context (not just diff
hunks); cross-checked the calendar's new widget-declaration fields (`views`,
lattice-scale `default_size`/`min_size`, dropped `max_size`) and the widgets' new
`--pk-scale` / container-query CSS against the ACTUAL current source of the sibling
`/workspace/phoenix_kit_dashboards` package (not assumed) to verify the duck-typed
contract is genuinely honored on both sides; did an arithmetic pixel-budget check of
the mini-month widget's rendered content against its declared minimum box size.

## Findings

### BUG-HIGH — mini-month widget silently clips a 6-row month at its own declared minimum size

`lib/phoenix_kit_calendar/web/mini_month_widget.ex`'s card-body wrapper changed from
`overflow-auto` to `overflow-hidden`:

```elixir
<div class="card-body p-3 flex items-center justify-center overflow-hidden">
```

`calendar.mini_month`'s declared `min_size` is `%{w: 8, h: 8}` (`lib/phoenix_kit_calendar.ex`)
— 8 lattice cells × the dashboards package's documented 25px nominal cell
(`phoenix_kit_dashboards/lib/phoenix_kit_dashboards/lattice.ex`) = a 200×200px nominal
box. After subtracting the dashboards frame chrome around a placed widget (outer
`m-[2px]` + `border` + the drag-handle/action-button bar in
`phoenix_kit_dashboards/lib/phoenix_kit_dashboards/web/builder_components.ex`) and this
widget's own `card-body p-3` padding, the actual available content height at min size
is **≈138px**.

`PhoenixLiveCalendar.Components.MiniCalendar`'s rendered content for a 6-row month
(header ~24px + day-name row ~20px + 6 week-rows × ~33px when a week has an event dot)
is **≈242px** — roughly **104px / ~3 week-rows too tall** for the available box. Because
the wrapper also has `items-center justify-center`, the overflow clips symmetrically
(top and bottom), so both the tail of the month and part of the header can vanish.

With the *previous* `overflow-auto`, a user could still scroll to see the clipped
weeks; `overflow-hidden` makes them simply gone, with no recovery, at exactly the box
size the widget itself advertises as its supported minimum. Several months a year need
6 grid rows, so this isn't an edge case.

**Fix applied:** reverted the card-body wrapper to `overflow-auto`
(`mini_month_widget.ex`), restoring scroll-to-recover behavior. Locked in with a new
test, `test/phoenix_kit_calendar/web/widget_test.exs` — "mini_month sizing... stays
scrollable at its declared min_size instead of hard-clipping" — asserting the
`card-body` renders with `overflow-auto`.

**Not fixed, flagged for follow-up:** this only restores the old safety net: it
doesn't make the mini-month fit its box at min size. Unlike the `Upcoming`/`Today`
widgets (which this same PR gave a genuine self-fit treatment via `container-type:size`
+ `cqh` clamped type + `--pk-scale`), `MiniMonthWidget` has no such treatment — it
can't, since `MiniCalendar`'s cell/dot sizes are fixed Tailwind classes owned by the
external `phoenix_live_calendar` dependency, not something this module controls
without wrapping it in its own scaling logic (e.g. a CSS `transform: scale()` container
driven by cq, or a taller `min_size`). Either fix is a real design decision beyond a
one-line correction, so it's left as a follow-up rather than attempted here.

### Contract verification (no issues found) — duck-typed `phoenix_kit_widgets/0` vs. `phoenix_kit_dashboards`

Checked every new/changed contract point in this PR against the ACTUAL current
`phoenix_kit_dashboards` source (sibling checkout at `/workspace/phoenix_kit_dashboards`),
since this is a one-way duck-typed contract with no compile-time check:

- **`views` key** — genuinely read by `PhoenixKitDashboards.Widget.from_map/2` /
  `normalize_views/2`; shape (`%{key:, name:, min_size: %{w:, h:}}`) matches exactly;
  per-view `min_size` is honored by `Widget.min_size_for/2` for resize-hook clamping.
- **Dropped `max_size`** — confirmed a pure no-op both before and after this PR:
  `phoenix_kit_dashboards` hardcodes the struct's `max_size` to the lattice's global
  max regardless of what a provider supplies (explicit comment in `widget.ex`: a
  provider max "serves nobody" on the screenful lattice). The calendar's old
  `max_size: %{w: 6, h: 4}` was already being silently discarded.
- **Lattice-scale `default_size`/`min_size`** — genuinely interpreted as 25px-nominal
  cells by `phoenix_kit_dashboards`; the PR's new `w:12,h:8`-scale values are the
  correct order of magnitude (matching the dashboards package's own built-in widget
  defaults), whereas the *old* small-scale values (`w:3,h:2`) would have been clamped
  up to the lattice's floor and rendered far smaller than intended.
- **`--pk-scale`** — a real CSS custom property, actively set by the dashboards
  package's grid/free-fit hooks on the canvas ancestor (not aspirational), and already
  consumed the identical way by the dashboards package's own built-in
  `ModuleStatsWidget`. The calendar widgets' `clamp(... var(--pk-scale, 1) ...)` usage
  matches this established, working pattern.
- **`:view` assign** — `phoenix_kit_dashboards` passes exactly this assign name/shape
  to every placed widget's `live_component`, sourced from the per-instance persisted
  view selection; matches what `UpcomingWidget`/`TodayAgendaWidget` read via
  `assigns[:view]`.

One nuance, not a defect: the dashboards package's own built-in widgets use `cq` length
units but not `@container (...)` at-rule blocks; this PR's use of an actual
`@container (max-height: 26px) { ... }` block in the agenda widgets is a step beyond
existing precedent in that codebase. It's architecturally sound (each row already has
its own `[container-type:size]`), but worth a quick manual/browser sanity check since
nothing else in the ecosystem exercises that exact path yet.

### IMPROVEMENT-MEDIUM — `TodayAgendaWidget`'s view logic had zero test coverage

`UpcomingWidget` and `TodayAgendaWidget` both got the identical new `view`
(`detailed`/`compact`, defaulting to `detailed` on anything else) rendering logic, but
the PR's new "views" test `describe` block only exercised `UpcomingWidget`. A future
refactor could silently break `TodayAgendaWidget`'s compact rendering or its
unknown-view fallback with nothing to catch it.

**Fix applied:** added the same two tests for `TodayAgendaWidget` ("compact renders
one-line rows without the meta line" / "an unknown view falls back to detailed"),
mirroring the existing `UpcomingWidget` coverage.

### No other correctness issues found

- `assigns[:view] in ["detailed", "compact"] && assigns[:view]) || "detailed"` (both
  widgets) correctly defaults on `nil`, an unrecognized string, or absence — verified
  against the "unknown view falls back to detailed" tests.
- The old `WidgetSupport.compact?/1` height-flag helper was fully removed with no
  dangling callers (`compact?`/`:compact` grep across `lib/` and `test/` — no hits).
  `fit_text/3`'s `clamp(min, preferred, max)` argument order is consistent across all
  eight call sites (min < max in every case).
- `Upcoming`'s padding-slot count scales to the user's `limit` setting (up to 20)
  rather than a fixed floor like `Today`'s (fixed at 4). At a high `limit` with few
  real events this reserves a lot of visually empty slot space — a deliberate
  documented tradeoff (the `N-SLOT self-fit: the limit budget of slots` comment), not
  a bug: it keeps the widget's visual rhythm stable as events come and go, rather than
  jumping around.
- `mix format`/`compile --warnings-as-errors`/`credo --strict` were all clean already
  on the merged PR; no dead code or leftover references to the removed API.

## Validation gate

Run with `PHOENIX_KIT_PATH=../phoenix_kit` per `AGENTS.md`'s cross-repo-gate note
(`PHOENIX_LIVE_CALENDAR_PATH` intentionally left unset — no local checkout of that repo
exists in this workspace, so it resolves to the published Hex package instead, which is
within the module's supported range).

- **Environment fix required first:** `mix test` initially failed to even boot
  (`Could not start application ueberauth_apple`) — `mix.lock` was stale relative to
  the local `phoenix_kit` path dependency, which recently dropped `ueberauth_apple` /
  `httpoison` (unmaintained + CVE cleanup, per its own `mix.exs` comments). `mix
  deps.get` resolved it; `mix.lock` in this repo was already free of those entries
  after regeneration (no diff to commit) — this was pre-existing local-checkout drift,
  unrelated to PR #4's own changes.
- `mix format --check-formatted` — clean.
- `mix compile --warnings-as-errors` (dev and test) — clean, no warnings, before and
  after this review's fixes.
- `mix credo --strict` — 339 mods/funs analyzed, no issues, before and after.
- `mix test` — **could not run the DB-backed portion**: no PostgreSQL server and no
  root access in this sandbox (same constraint noted in the PR #2 review). 12
  DB-independent tests pass; 103 DB-dependent tests are tagged and skipped (was 100
  before this review added 3 new tests — all three, including the mini-month
  regression test, compile and get correctly tag-excluded, confirming they're
  well-formed). **The DB-backed suite (`mix test.setup && mix test`) should still be
  run in a real environment with Postgres before/after merge** to actually execute the
  new regression tests.

## Not addressed

Per `AGENTS.md`: **"Releases/version bumps are Max-only — PRs land at the current
version."** No version bump, CHANGELOG entry, or Hex publish was performed, regardless
of how this review was invoked. The version remains `0.1.0`.
