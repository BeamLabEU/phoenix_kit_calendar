defmodule PhoenixKitCalendar.ExternalSourcesTest do
  @moduledoc """
  Other modules' read-only items on a person's calendar: which sources are
  on offer, what an item must be, that a broken source costs nothing but
  its own items, and the per-person hide switch.
  """

  use PhoenixKitCalendar.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCalendar.ExternalSources

  defmodule Provider do
    @moduledoc false
    def phoenix_kit_calendar_sources do
      [
        %{key: "meetings", label: "Client meetings", items: {__MODULE__, :items}},
        %{key: "broken", label: "Broken", items: {__MODULE__, :boom}},
        %{key: "odd", label: "Odd", items: {__MODULE__, :odd}},
        # the same key twice: the first one stands
        %{key: "meetings", label: "Impostor", items: {__MODULE__, :boom}},
        %{label: "no key", items: {__MODULE__, :items}},
        %{key: "no_fun", label: "No function", items: :nope},
        %{
          key: "off",
          label: "Module off",
          module_key: "no_such_module",
          items: {__MODULE__, :items}
        }
      ]
    end

    def items(user_uuid, from, until) do
      send(:persistent_term.get({__MODULE__, :pid}), {:asked, user_uuid, from, until})

      %{
        items: [
          %{id: "b", title: "Later", starts_at: ~U[2026-10-12 09:00:00Z], status: "planned"},
          %{id: "a", title: "Sooner", starts_at: ~U[2026-10-11 09:00:00Z], status: "cancelled"},
          # not drawable: no start, no title
          %{id: "c", title: "No start"},
          %{id: "d", starts_at: ~U[2026-10-11 09:00:00Z]},
          # drawable only if the optional fields are what the page reads them as
          %{id: "e", title: "Bad end", starts_at: ~U[2026-10-11 09:00:00Z], ends_at: "noon"},
          %{id: "f", title: "Bad day", starts_at: ~U[2026-10-11 09:00:00Z], starts_on: "today"},
          %{id: "g", title: "Bad place", starts_at: ~U[2026-10-11 09:00:00Z], location: %{}}
        ],
        truncated: true
      }
    end

    def boom(_user_uuid, _from, _until), do: raise("boom")
    def odd(_user_uuid, _from, _until), do: :nonsense
  end

  defmodule Many do
    @moduledoc false
    def items(_user_uuid, _from, _until) do
      items =
        for n <- 1..301 do
          %{id: "m#{n}", title: "Item #{n}", starts_at: DateTime.add(~U[2026-10-01 00:00:00Z], n)}
        end

      %{items: items, truncated: false}
    end
  end

  defmodule RaisingProvider do
    @moduledoc false
    def phoenix_kit_calendar_sources, do: raise("boom")
  end

  setup do
    :persistent_term.put({Provider, :pid}, self())

    Application.put_env(:phoenix_kit_calendar, :source_providers, [RaisingProvider, Provider])
    on_exit(fn -> Application.delete_env(:phoenix_kit_calendar, :source_providers) end)
    :ok
  end

  test "list/0: well-formed sources of enabled modules, each key once; a raising provider is skipped" do
    assert [
             %{key: "meetings", label: "Client meetings", module_key: nil},
             %{key: "broken"},
             %{key: "odd"}
           ] = ExternalSources.list()
  end

  test "items/4: tagged with the source, soonest first, undrawable ones dropped; a broken source gives nothing" do
    user = Ecto.UUID.generate()
    from = ~U[2026-10-01 00:00:00Z]
    until = ~U[2026-11-01 00:00:00Z]

    assert %{items: items, truncated: true} =
             ExternalSources.items(ExternalSources.list(), user, from, until)

    assert Enum.map(items, &{&1.source, &1.id, &1.title}) == [
             {"meetings", "a", "Sooner"},
             {"meetings", "b", "Later"}
           ]

    assert_received {:asked, ^user, ^from, ^until}
    assert ExternalSources.item_id(hd(items)) == "ext:meetings:a"
    assert ExternalSources.item_id?("ext:meetings:a")
    refute ExternalSources.item_id?(Ecto.UUID.generate())
  end

  test "items/4: more than the cap in total is reported as truncated" do
    assert %{items: items, truncated: true} =
             ExternalSources.items(
               [%{key: "many", label: "Many", module_key: nil, items: {__MODULE__.Many, :items}}],
               Ecto.UUID.generate(),
               ~U[2026-10-01 00:00:00Z],
               ~U[2026-11-01 00:00:00Z]
             )

    assert length(items) == 300
  end

  test "items/4 with nobody to ask for, or no sources, is empty" do
    assert ExternalSources.items(
             [],
             Ecto.UUID.generate(),
             ~U[2026-10-01 00:00:00Z],
             ~U[2026-11-01 00:00:00Z]
           ) ==
             %{items: [], truncated: false}

    assert ExternalSources.items(
             ExternalSources.list(),
             nil,
             ~U[2026-10-01 00:00:00Z],
             ~U[2026-11-01 00:00:00Z]
           ) ==
             %{items: [], truncated: false}
  end

  test "hiding a source is remembered on the user, and undone the same way" do
    {:ok, user} =
      Auth.register_user(%{
        email: "src_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    assert ExternalSources.hidden(user) == []

    assert ExternalSources.set_hidden(user, "meetings", true) == ["meetings"]
    user = Auth.get_user(user.uuid)
    assert ExternalSources.hidden(user) == ["meetings"]

    assert ExternalSources.set_hidden(user, "meetings", false) == []
    assert ExternalSources.hidden(Auth.get_user(user.uuid)) == []
  end

  test "set_hidden/4 builds on the keys the page holds, not on a stale user struct" do
    {:ok, user} =
      Auth.register_user(%{
        email: "src_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    assert ExternalSources.set_hidden(user, ["a"], "b", true) == ["a", "b"]
    assert ExternalSources.hidden(Auth.get_user(user.uuid)) == ["a", "b"]
    assert ExternalSources.set_hidden(user, ["a", "b"], "a", false) == ["b"]
  end

  test "a user that is not a stored one still gets the answer for this visit" do
    assert ExternalSources.hidden(nil) == []
    assert ExternalSources.set_hidden(nil, "meetings", true) == ["meetings"]

    assert ExternalSources.set_hidden(%{custom_fields: nil}, "meetings", true) ==
             ["meetings"]
  end
end
