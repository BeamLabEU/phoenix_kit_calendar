# PR #9 — External sources: other modules' read-only items on a person's calendar

- **Author:** Max Don
- **Merged as:** `ed024d6` (squash)
- **Reviewer:** Claude
- **Date:** 2026-10-14

## Scope

New `ExternalSources` module: any PhoenixKit module may export
`phoenix_kit_calendar_sources/0`; the calendar asks each source for the window
on screen on every load, draws the answers read-only on the viewer's OWN
calendar, lets the viewer hide a source (stored on `custom_fields`), and opens
an item read-only in the event modal. Also the lock moves to phoenix_kit 2.62.2
and phoenix_live_calendar 0.5.1.

## Verified

- Items are fetched only while the viewer's own uuid is in the visible
  selection, so a colleague's calendar never shows the viewer's items.
- `"ext:"` ids can't collide with an event uuid, and the `ext:` click clause
  touches no event data and never reaches `Events.get_event/2`.
- `status_atom/1` maps unknown free-text statuses to `:confirmed` (no
  `String.to_atom`).
- A raising / exiting / nonsense source or provider contributes nothing.
- HEEx escapes every item field.

## Findings

### BUG - MEDIUM — toggling a second source un-hides the first

`set_hidden/3` computed the new list from `hidden(user)`, where `user` is
`scope.user` as of mount; the updated user returned by core's
`merge_user_custom_fields/3` is discarded. With two sources, hiding `crm` then
`docs` saved `["docs"]` — `crm` came back on the next page load (the page itself
looked right, because it uses its own `hidden_sources` assign). The PR's tests
had a single source, so it never showed.

**Fixed:** new `set_hidden/4` builds on the keys the caller already holds;
`/3` delegates to it. `CalendarLive` passes `@hidden_sources`. Tests: unit
(`set_hidden/4`) and a LiveView test with two sources asserting both the page and
the stored `custom_fields`.

### IMPROVEMENT - MEDIUM — optional item fields were not validated

`item?/1` checked `id`, `title`, `starts_at` only, while the page does
`shift_to_offset(item.ends_at)`, `Date.add(item.starts_on, …)` and renders
`label` / `location` / `url`. An item with `ends_at: "noon"` or a map as
`location` crashed the LiveView, against the moduledoc's promise that nonsense
contributes nothing and the person's own events still show.

**Fixed:** `item?/1` also requires each optional field to be nil or its
expected type. Test added.

### IMPROVEMENT - MEDIUM — an all-day item read as a clock time in the modal

`item_when/2` always formatted `starts_at` shifted into the viewer's zone, so an
all-day item (contract: `starts_on` / exclusive `ends_on`) showed e.g.
`2026-10-15 00:00`, or the previous day west of UTC. **Fixed:** all-day items
show the date, or `first – last` with the exclusive end converted to its last
day. LiveView test added.

### IMPROVEMENT - MEDIUM — `function_exported?/3` without `Code.ensure_loaded?/1`

`persist/2` feature-detects `Auth.merge_user_custom_fields/3` with
`function_exported?/3` alone — the AGENTS.md landmine: a not-yet-loaded `Auth`
silently skips saving the hidden choice. **Fixed:** `Code.ensure_loaded?/1` first.

### NITPICK — the 300 cap never reported `truncated`

`items/4` cut at 300 after merging but only forwarded the sources' own
`truncated` flags. **Fixed:** `truncated` is also true when the merged list
exceeded the cap. (`@external_truncated?` is still assigned but nothing renders
it — left as is; a visible hint is a product call.)

### NITPICK — not fixed on purpose

- A source's `url` goes straight into `<.link navigate>`. Sources are trusted
  code from installed modules and the client router rejects non-local targets,
  so no sanitising was added.
- `ExternalSources.list/0` runs in `mount/3` (registry reads, which may touch
  the settings cache); it matches the surrounding mount, which already calls
  `Sources.*`. Moving all of it to `handle_params` is a separate cleanup.

## Validation

`mix format`, `mix test` (142 tests including the integration suite against the local DB, 0 failures), `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer 0 errors).
