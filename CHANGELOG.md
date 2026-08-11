## 0.2.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## 0.2.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

## 0.1.0 - 2026-07-11

Initial release. Personal calendars for PhoenixKit — one implicit calendar per
user, with fine-grained sub-permissions (`calendar.view_others` /
`calendar.edit_others`) controlling access to *other* people's calendars.

### Added
- **`Web.CalendarLive`** (`/admin/calendar`) — month view via
  `phoenix_live_calendar`'s `CalendarComponent`, create/edit/delete modals,
  a "Calendars" panel for switching or overlaying other users' calendars
  (permission-gated), and live cross-tab updates via a scoped PubSub topic.
- **`Events` context** — the authorization boundary for all calendar reads
  and mutations. Every function authorizes against the target calendar's
  owner via `Scope.can?/2`; mutations are load-then-authorize against the
  persisted owner, and `owner_uuid` is never cast from user-supplied attrs.
- **Timed and all-day events** (`starts_at`/`ends_at` vs `starts_on`/`ends_on`,
  exclusive end, iCal-style), stored in true UTC and displayed/entered in the
  viewer's offset-hours timezone, with a cross-timezone indicator + explicit
  "Use their timezone" entry mode when editing another owner's calendar.
- **Participants** — invite platform users, staff, or CRM contacts to an
  event via a cross-source search picker with load-more pagination,
  cross-source de-duplication (linked user > staff > CRM contact), and
  source-level invite permission gating.
- **Three dashboard widgets** (`calendar.upcoming`, `calendar.today`,
  `calendar.mini_month`) via the duck-typed `phoenix_kit_widgets/0` contract,
  each scoped strictly to the viewer's own calendar and rendering
  defensively (nil scope/settings/size never crashes the host dashboard).
- Activity logging on every mutation (`calendar_event.created/updated/deleted`).

### Fixed
- Dashboard widgets (`Upcoming`, `Today`) sorted events by default term
  order on a `DateTime` struct instead of chronologically, which silently
  broke "soonest first" / "all-day first" whenever the event set crossed a
  month boundary. Both now sort with an explicit `DateTime` comparator.
- `CalendarLive.mount/3` ran an ungated database query for the people panel
  that never refreshed for the life of the socket (a stale roster after
  mount) and duplicated on the disconnected+connected mount pair. The load
  now happens in `handle_params/3`, in line with the rest of the LiveView's
  fresh-scope-on-every-navigation convention.
- `Events.tap_log/4` ran activity logging and the PubSub live-update
  broadcast in the same rescue block, so a logging failure could silently
  suppress the broadcast too. The two are now isolated from each other.
