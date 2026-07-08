defmodule PhoenixKitCalendar.Paths do
  @moduledoc """
  Centralized path helpers for the Calendar module.

  All paths go through `PhoenixKit.Utils.Routes.path/1` for prefix/locale
  handling — never hardcode `"/admin/calendar"` in LiveViews.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/calendar"

  @doc "The calendar page (own calendar)."
  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  @doc """
  The calendar page with a layer selection. `people` is the compact URL
  form built by the LiveView: `nil` (own calendar — no param), `"all"`
  (every calendar), or a comma-joined uuid list. Only meaningful for
  viewers holding `calendar.view_others` — the LiveView sanitizes the
  param against permissions on every mount/patch.
  """
  @spec people(String.t() | nil) :: String.t()
  def people(nil), do: index()
  def people(param), do: Routes.path("#{@base}?people=#{param}")
end
