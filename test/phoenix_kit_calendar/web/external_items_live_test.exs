defmodule PhoenixKitCalendar.Web.ExternalItemsLiveTest do
  @moduledoc """
  Another module's items on the calendar page: drawn on the viewer's own
  calendar only, hidden per source with a switch that is remembered, and
  opened read-only with the way to where they are managed.
  """

  use PhoenixKitCalendar.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCalendar.ExternalSources

  @path "/en/admin/calendar"

  defmodule Provider do
    @moduledoc false
    def phoenix_kit_calendar_sources,
      do: [
        %{key: "crm", label: "Client interactions", items: {__MODULE__, :items}},
        %{key: "docs", label: "Deadlines", items: {__MODULE__, :none}}
      ]

    def none(_user_uuid, _from, _until), do: %{items: [], truncated: false}

    def items(user_uuid, _from, _until) do
      today = Date.utc_today()

      %{
        items: [
          %{
            id: "one",
            title: "Site visit for #{String.slice(user_uuid, 0, 8)}",
            label: "Meeting",
            starts_at: DateTime.new!(today, ~T[09:00:00], "Etc/UTC"),
            ends_at: DateTime.new!(today, ~T[10:30:00], "Etc/UTC"),
            status: "planned",
            location: "ANDI showroom",
            url: "/en/admin/crm/companies/x?tab=interactions"
          },
          %{
            id: "allday",
            title: "Trade fair",
            all_day: true,
            starts_on: Date.add(today, 1),
            ends_on: Date.add(today, 4),
            starts_at: DateTime.new!(Date.add(today, 1), ~T[00:00:00], "Etc/UTC")
          },
          %{
            id: "two",
            title: "Called off",
            starts_at: DateTime.new!(today, ~T[13:00:00], "Etc/UTC"),
            status: "cancelled"
          }
        ],
        truncated: false
      }
    end
  end

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitCalendar.enable_system()
    Application.put_env(:phoenix_kit_calendar, :source_providers, [Provider])
    on_exit(fn -> Application.delete_env(:phoenix_kit_calendar, :source_providers) end)

    _owner = create_user()
    %{conn: conn, me: create_user(), other: create_user()}
  end

  defp create_user do
    {:ok, user} =
      Auth.register_user(%{
        email: "ext_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp login(conn, user, perms),
    do: put_test_scope(conn, fake_scope(user_uuid: user.uuid, permissions: perms))

  test "the viewer's items are on their own calendar, beside a switch for the source", %{
    conn: conn,
    me: me
  } do
    {:ok, _view, html} = conn |> login(me, ["calendar"]) |> live(@path)

    assert html =~ "Site visit for #{String.slice(me.uuid, 0, 8)}"
    assert html =~ "Called off"
    assert html =~ ~s(id="calendar-source-crm")
    assert html =~ "Client interactions"
    assert html =~ ~s(aria-pressed="true")
  end

  test "they are the viewer's, not a colleague's: gone when only someone else's calendar is shown",
       %{conn: conn, me: me, other: other} do
    conn = login(conn, me, ["calendar", "calendar.view_others"])

    {:ok, _view, html} = live(conn, @path <> "?people=#{other.uuid}")
    refute html =~ "Site visit for"

    {:ok, _view, html} = live(conn, @path <> "?people=#{me.uuid},#{other.uuid}")
    assert html =~ "Site visit for #{String.slice(me.uuid, 0, 8)}"
  end

  test "the switch hides the source and brings it back", %{conn: conn, me: me} do
    {:ok, view, _html} = conn |> login(me, ["calendar"]) |> live(@path)

    html = view |> element("#calendar-source-crm") |> render_click()
    refute html =~ "Site visit for"
    assert html =~ ~s(aria-pressed="false")

    html = view |> element("#calendar-source-crm") |> render_click()
    assert html =~ "Site visit for"
  end

  test "toggling a second source keeps the first one hidden, on the page and in storage", %{
    conn: conn,
    me: me
  } do
    {:ok, view, _html} = conn |> login(me, ["calendar"]) |> live(@path)

    view |> element("#calendar-source-crm") |> render_click()
    html = view |> element("#calendar-source-docs") |> render_click()

    refute html =~ "Site visit for"
    assert ExternalSources.hidden(Auth.get_user(me.uuid)) == ["crm", "docs"]

    html = view |> element("#calendar-source-docs") |> render_click()
    refute html =~ "Site visit for"
    assert ExternalSources.hidden(Auth.get_user(me.uuid)) == ["crm"]
  end

  test "an unknown source key changes nothing", %{conn: conn, me: me} do
    {:ok, view, _html} = conn |> login(me, ["calendar"]) |> live(@path)
    assert render_click(view, "toggle_source", %{"key" => "nope"}) =~ "Site visit for"
  end

  test "an item opens read-only: when, where, whose, and the way there — nothing to save or delete",
       %{conn: conn, me: me} do
    {:ok, view, _html} = conn |> login(me, ["calendar"]) |> live(@path)

    send(view.pid, {:calendar_event_click, ExternalSources.item_id(%{source: "crm", id: "one"})})
    html = render(view)

    assert html =~ ~s(id="calendar-external-item")
    assert html =~ "ANDI showroom"
    assert html =~ "Meeting"
    assert html =~ "From Client interactions"
    assert html =~ "/en/admin/crm/companies/x?tab=interactions"
    refute html =~ ~s(phx-click="delete_event")
    # the Save button (the modal itself names the form in a data attribute)
    refute html =~ ~r/\sform="calendar-event-form"/

    send(view.pid, {:calendar_event_click, ExternalSources.item_id(%{source: "crm", id: "two"})})
    assert render(view) =~ "Cancelled"

    # an all-day item is dates (the exclusive end shown as its last day), not a clock time
    today = Date.utc_today()

    send(
      view.pid,
      {:calendar_event_click, ExternalSources.item_id(%{source: "crm", id: "allday"})}
    )

    html = render(view)

    assert html =~
             "#{Date.to_iso8601(Date.add(today, 1))} – #{Date.to_iso8601(Date.add(today, 3))}"

    refute html =~ "00:00"

    # closing it leaves the page ready for a real event again
    render_click(view, "close_modal", %{})
    refute render(view) =~ ~s(id="calendar-external-item")
  end

  test "an id of an item that is no longer there closes the dialog quietly", %{conn: conn, me: me} do
    {:ok, view, _html} = conn |> login(me, ["calendar"]) |> live(@path)
    send(view.pid, {:calendar_event_click, "ext:crm:gone"})
    refute render(view) =~ ~s(id="calendar-external-item")
  end
end
