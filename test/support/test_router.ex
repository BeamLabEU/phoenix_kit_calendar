defmodule PhoenixKitCalendar.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitCalendar.Paths` so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  `phoenix_kit_settings` table is unavailable. Admin paths carry the
  default locale (`/en/admin/calendar`) on a multilingual site and on every
  core before 2.62; from 2.62 a single-language site writes
  `/admin/calendar`. Both are mounted.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitCalendar.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/", PhoenixKitCalendar.Web do
    pipe_through(:browser)

    live_session :calendar_test,
      layout: {PhoenixKitCalendar.Test.Layouts, :app},
      on_mount: {PhoenixKitCalendar.Test.Hooks, :assign_scope} do
      # Both shapes the page's own URL takes: with the language segment (a
      # multilingual site, and every site before core 2.62) and without it
      # (a single-language site from core 2.62 on, which a test site is).
      live("/en/admin/calendar", CalendarLive, :index)
      live("/admin/calendar", CalendarLive, :index, as: :bare_calendar)
    end
  end
end
