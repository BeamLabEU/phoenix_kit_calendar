# PR #8 — Activity logging through core's log/3

- **Author:** Max Don
- **Merged as:** `a251b5a` (squash)
- **Reviewer:** Claude
- **Date:** 2026-09-26

## Scope

Event and participant activity entries move from a guarded, rescued
`PhoenixKit.Activity.log/1` call to core's never-raising `log/3`; the actor is
read with `PhoenixKitWeb.Actor.uuid/1` instead of `Scope.user_uuid/1`; the
`:phoenix_kit` floor rises to `>= 2.38.0 and < 3.0.0`.

## Verified

- **Floor is correct.** Checked the published tarballs: 2.37.5 has neither
  `PhoenixKitWeb.Actor` nor `Activity.log/3`; 2.38.0 has both, and its `log/1`
  already catches `:exit`/`:throw`, so "never raises" holds at the floor.
- `log/3` defaults `mode` to `"manual"`, so dropping the explicit `mode:` keeps
  the logged rows identical (AGENTS.md's description stays accurate).
- The `Keyword.get(opts, :actor_uuid, Actor.uuid(scope))` default and
  `Actor.uuid(nil)` are safe for a nil scope.
- `Events.own?/2` already read the user via `Scope.user/1` + `%{uuid: _}`, so
  the context's authorization was map-user tolerant before this PR.

## Findings

### IMPROVEMENT - MEDIUM — the actor-read migration stopped at the context

The PR's rationale is that `Scope.user_uuid/1` matches only
`%Scope{user: %User{}}`, so a scope carrying a plain-map user loses its uuid.
It fixed the two context call sites but left the two viewer reads in the web
layer: `CalendarLive.mount/3` (`own_uuid`, which seeds the `{me}` layer and the
owner picker) and `WidgetSupport.viewer_uuid/1` (every widget's query). With a
map-user scope the context would log and authorize the user while the page
showed no own calendar and the widgets rendered empty.

**Fixed:** both now use `PhoenixKitWeb.Actor.uuid/1`; `viewer_uuid/1` collapses
to a one-liner (`Actor.uuid/1` has a catch-all clause and never raises), and the
now-unused `Scope` alias in `WidgetSupport` is dropped.

### IMPROVEMENT - MEDIUM — `notify_added/3` rescues but does not catch exits

The rewritten comment says a failure resolving participants "must not undo the
participants already saved". `Sources.resolve_user/1` runs a query after the
commit; a pool checkout timeout exits rather than raises, so it went past the
`rescue` and crashed the caller (the LiveView) after a successful save. The
event path is covered by core's `log/1`, which catches exits — the participant
path was the asymmetric one.

**Fixed:** added `catch :exit, _ -> :ok` alongside the rescue.

### IMPROVEMENT - MEDIUM — the fixed bug had no test

The PR fixes a map-user actor but adds no test for it.

**Fixed:** `activity_test.exs` creates an event under a scope whose user is a
plain map and asserts the actor is logged; `widget_test.exs` pins
`WidgetSupport.viewer_uuid/1` for struct user, map user, nil scope and nil user.

### NITPICK — stale dependency comment in `mix.exs`

The comment above the `:phoenix_kit` pin still explained 1.7.179 / 1.7.184
requirements, which a 2.38.0 floor makes moot. **Fixed:** trimmed.

## Validation

`mix format`, `mix test` (128 tests including the 2 new ones, integration suite against the
local DB, 0 failures), `mix precommit` clean.
