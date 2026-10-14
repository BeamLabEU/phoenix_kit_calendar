defmodule PhoenixKitCalendar.ExternalSources do
  # `apply/3` on purpose: a source is another application's module, known
  # only by the name it declared.
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  @moduledoc """
  Read-only items other modules put on a person's calendar — a CRM
  interaction they are a party to, say. The calendar never copies them: it
  asks each source for the window on screen, every time, so an item that
  moved or was cancelled is right on the next look and there is nothing to
  keep in sync.

  ## Declaring a source

  Any PhoenixKit module (or a module listed under
  `config :phoenix_kit_calendar, source_providers: [...]`) may export
  `phoenix_kit_calendar_sources/0`:

      def phoenix_kit_calendar_sources do
        [
          %{
            key: "crm",                         # unique, stable
            label: "Client interactions",       # what the toggle says
            module_key: "crm",                  # the source is offered only while this module is on
            items: {MyApp.CalendarItems, :for_user}
          }
        ]
      end

  `items` is called as `fun.(user_uuid, from, until)` with UTC `DateTime`s
  and answers `%{items: [item], truncated: boolean}`. THE SOURCE decides
  what the user may see — it is handed the user, and must return only what
  is theirs. Return what overlaps `[from, until)`, soonest first, capped.

  ## An item

      %{
        source: "crm",              # the source key; with `id`, the identity
        id: "…",                    # stable within the source
        title: "Site visit",
        starts_at: ~U[…],           # UTC; required
        ends_at: ~U[…] | nil,       # nil = nobody said; drawn as an hour
        all_day: false,             # true → `starts_on` / `ends_on` dates (exclusive end)
        status: "planned",          # free text; "cancelled" is struck through
        label: "Meeting" | nil,     # the kind, for a badge
        location: "…" | nil,
        url: "/admin/…" | nil,      # where it is managed — the only way to change it
        updated_at: ~U[…] | nil
      }

  No recurrence (a source expands its own), no description or body (a
  calendar is seen over shoulders), and no merging with an event someone
  made by hand: two things that look alike are two things.

  ## Hiding a source

  Per person: `hidden/1` and `set_hidden/3`, kept on the user's
  `custom_fields` under `"calendar_hidden_sources"`.

  A source that raises, times out or answers nonsense contributes nothing;
  the person's own events must still show.
  """

  require Logger

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions

  @callback_name :phoenix_kit_calendar_sources
  @hidden_field "calendar_hidden_sources"
  @cap 300

  @type source :: %{
          key: String.t(),
          label: String.t(),
          module_key: String.t() | nil,
          items: {module(), atom()}
        }

  @doc "The sources on offer right now: declared, well-formed, their module enabled."
  @spec list() :: [source()]
  def list do
    provider_modules()
    |> Enum.flat_map(&declared/1)
    |> Enum.flat_map(&normalize/1)
    |> Enum.uniq_by(& &1.key)
    |> Enum.filter(&available?/1)
  rescue
    e ->
      Logger.warning("[PhoenixKitCalendar] source discovery failed: #{Exception.message(e)}")
      []
  end

  defp provider_modules do
    discovered =
      if Code.ensure_loaded?(PhoenixKit.ModuleRegistry),
        do: PhoenixKit.ModuleRegistry.all_modules(),
        else: []

    configured =
      :phoenix_kit_calendar
      |> Application.get_env(:source_providers, [])
      |> List.wrap()
      |> Enum.filter(&is_atom/1)

    (discovered ++ configured)
    |> Enum.uniq()
    # ensure_loaded before function_exported?: the latter never loads a module
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, @callback_name, 0)))
  rescue
    _ -> []
  end

  defp declared(module) do
    List.wrap(apply(module, @callback_name, []))
  rescue
    e ->
      Logger.warning(
        "[PhoenixKitCalendar] #{inspect(module)}.#{@callback_name}/0 raised: #{Exception.message(e)}"
      )

      []
  catch
    _kind, _reason -> []
  end

  defp normalize(%{} = map) do
    source = %{
      key: field(map, :key),
      label: field(map, :label),
      module_key: field(map, :module_key),
      items: field(map, :items)
    }

    if well_formed?(source) do
      [%{source | module_key: source.module_key && to_string(source.module_key)}]
    else
      Logger.warning("[PhoenixKitCalendar] dropping malformed calendar source #{inspect(map)}")
      []
    end
  end

  defp normalize(_other), do: []

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp well_formed?(%{key: key, label: label, items: {m, f}})
       when is_binary(key) and key != "" and is_binary(label) and is_atom(m) and is_atom(f),
       do: true

  defp well_formed?(_source), do: false

  defp available?(%{module_key: nil}), do: true

  defp available?(%{module_key: key}) do
    Permissions.feature_enabled?(key)
  rescue
    _ -> false
  end

  @doc "The keys of the sources this user has hidden, sorted."
  @spec hidden(map() | nil) :: [String.t()]
  def hidden(%{custom_fields: %{@hidden_field => keys}}) when is_list(keys),
    do: keys |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()

  def hidden(_user), do: []

  @doc """
  Hides or shows a source for the user, for good. Answers the new hidden
  keys — also when they could not be saved (an older core, a user that is
  not a stored one), so the page still does what was asked for this visit.
  """
  @spec set_hidden(map() | nil, String.t(), boolean()) :: [String.t()]
  def set_hidden(user, key, hidden?), do: set_hidden(user, hidden(user), key, hidden?)

  @doc """
  Like `set_hidden/3`, from the keys the caller already holds as hidden.
  A page that has toggled before must pass its own list: the user struct it
  was mounted with still carries the `custom_fields` of mount time, so
  reading `current` from it would drop every earlier toggle.
  """
  @spec set_hidden(map() | nil, [String.t()], String.t(), boolean()) :: [String.t()]
  def set_hidden(user, current, key, hidden?) when is_list(current) and is_binary(key) do
    next =
      if hidden?,
        do: Enum.sort(Enum.uniq([key | current])),
        else: List.delete(current, key)

    persist(user, next)
    next
  end

  defp persist(%User{} = user, keys) do
    # ensure_loaded before function_exported?: the latter never loads a module
    if Code.ensure_loaded?(Auth) and function_exported?(Auth, :merge_user_custom_fields, 3) do
      apply(Auth, :merge_user_custom_fields, [
        user,
        %{@hidden_field => keys},
        [ensure_definitions: false]
      ])
    end

    :ok
  rescue
    e ->
      Logger.warning("[PhoenixKitCalendar] hidden sources not saved: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp persist(_user, _keys), do: :ok

  @doc """
  The items of every source in `sources` for the user, in the window
  (UTC `DateTime`s), soonest first. `truncated` says a source had more
  than it gave.
  """
  @spec items([source()], String.t() | nil, DateTime.t(), DateTime.t()) ::
          %{items: [map()], truncated: boolean()}
  def items(sources, user_uuid, %DateTime{} = from, %DateTime{} = until)
      when is_list(sources) and is_binary(user_uuid) do
    results = Enum.map(sources, &source_items(&1, user_uuid, from, until))

    sorted =
      results
      |> Enum.flat_map(& &1.items)
      |> Enum.sort_by(& &1.starts_at, {:asc, DateTime})

    %{
      items: Enum.take(sorted, @cap),
      truncated: length(sorted) > @cap or Enum.any?(results, & &1.truncated)
    }
  end

  def items(_sources, _user_uuid, _from, _until), do: %{items: [], truncated: false}

  defp source_items(%{key: key, items: {mod, fun}}, user_uuid, from, until) do
    case apply(mod, fun, [user_uuid, from, until]) do
      %{items: items} = result when is_list(items) ->
        %{
          items: items |> Enum.filter(&item?/1) |> Enum.map(&Map.put(&1, :source, key)),
          truncated: Map.get(result, :truncated) == true
        }

      _ ->
        %{items: [], truncated: false}
    end
  rescue
    e ->
      Logger.warning("[PhoenixKitCalendar] source #{key} failed: #{Exception.message(e)}")
      %{items: [], truncated: false}
  catch
    :exit, _ -> %{items: [], truncated: false}
  end

  # The least an item must be to be drawn — and every optional field that the
  # page reads or renders is the type it reads it as, so one sloppy item
  # (a string for `ends_at`) is dropped instead of crashing the LiveView.
  defp item?(%{id: id, title: title, starts_at: %DateTime{}} = item)
       when is_binary(id) and is_binary(title) do
    optional?(item, :ends_at, &match?(%DateTime{}, &1)) and
      optional?(item, :starts_on, &match?(%Date{}, &1)) and
      optional?(item, :ends_on, &match?(%Date{}, &1)) and
      optional?(item, :label, &is_binary/1) and
      optional?(item, :location, &is_binary/1) and
      optional?(item, :url, &is_binary/1) and
      optional?(item, :status, &is_binary/1)
  end

  defp item?(_), do: false

  defp optional?(item, field, valid?) do
    case Map.get(item, field) do
      nil -> true
      value -> valid?.(value)
    end
  end

  @doc "The id an item has on the calendar grid — never a stored event's uuid."
  @spec item_id(map()) :: String.t()
  def item_id(%{source: source, id: id}), do: "ext:#{source}:#{id}"

  @doc "Whether a grid id is an external item's."
  @spec item_id?(term()) :: boolean()
  def item_id?("ext:" <> _), do: true
  def item_id?(_), do: false
end
