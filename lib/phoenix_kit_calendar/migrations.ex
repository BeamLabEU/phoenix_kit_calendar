defmodule PhoenixKitCalendar.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_calendar` — the protocol
  core's `mix phoenix_kit.update` discovers through `migration_module/0`:
  `current_version/0`, `migrated_version_runtime/1`, an idempotent `up/1` and a
  version-aware `down/1`. Same shape as `phoenix_kit_locations`' chain.

  ## What V1 is

  An ADOPTION step for the two tables core's chain creates for this module:
  `phoenix_kit_calendar_events` and `phoenix_kit_calendar_event_participants`. Core's V141 created them, above the V135 baseline, and no later core version reshapes them. The statements below re-state what a fresh core install builds today, with core's exact object names.

    * On every existing install the tables are already there: each `CREATE
      TABLE IF NOT EXISTS`, guarded `DO $$ … pg_constraint … $$` block and
      `CREATE INDEX IF NOT EXISTS` finds its target and does nothing. The only
      new object is the `pkcal_schema:1` marker.
    * On an install whose core no longer creates the tables, the same
      statements create them, identical to what core built.
      `test/phoenix_kit_calendar/migrations_build_alone_test.exs` proves that against
      core's chain (core's `PhoenixKit.TestSupport.ModuleChainCheck`).

  From V1 on, this chain owns the tables' shape: a change to them is a new
  version here, never a core migration (core enforces that since V223; see
  core's `dev_docs/plans/2026-10-25-module-table-ownership.md`). Until core's
  `ExpectedSchema` manifest hands these tables over, a version that reshapes an
  object the manifest declares must first take it out of the manifest, or
  `mix phoenix_kit.repair` restores the old shape; a version that only adds
  objects the manifest never names needs no core step.

  ## What `down/1` is NOT

  `down/1` rewrites the version marker; it never drops a table. The rows are
  people's calendar events, and on every current install core created the
  tables.
  `test/phoenix_kit_calendar/migrations_test.exs` pins this by asserting that no
  statement this module can emit matches `DROP`, `TRUNCATE` or `DELETE`.

  ## Adding a version

  1. Append the new statements to `up_statements/2` behind `target >= N`
     (never edit V1's statements: hosts past V1 never re-run them).
  2. Bump `@current_version`.

  The migrated version is a `pkcal_schema:<N>` `COMMENT ON TABLE` marker on
  `phoenix_kit_calendar_events`; a table without one reads as version 0 — the shape
  core built before this chain existed.
  """

  use Ecto.Migration

  @current_version 1
  @marker_prefix "pkcal_schema:"
  @version_table "phoenix_kit_calendar_events"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkcal_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc "The chain version read from INSIDE a migration (migration repo)."
  def migrated_version(opts \\ []) do
    prefix = validated_prefix(opts)
    %{rows: rows} = repo().query!(marker_query(), [prefix])
    rows |> List.first() |> marker_to_version()
  end

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pkcal_schema:<N>` marker when present; a marker-less table
  reads as `0` (core's shape — V1 is purely adoptive, there is no pre-chain
  content to defend).

  `catch :exit` matters as much as `rescue`: a dead or unstarted pool exits
  rather than raising, and `mix phoenix_kit.status` calls this across every
  installed module.
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    case PhoenixKit.RepoHelper.repo().query(marker_query(), [prefix]) do
      {:ok, %{rows: rows}} -> rows |> List.first() |> marker_to_version()
      _ -> 0
    end
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed").
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc "Applies every chain version up to `target` (`:version` in `opts`, default `current_version/0`); idempotent."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)

    target =
      if is_list(opts), do: Keyword.get(opts, :version, @current_version), else: @current_version

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops a table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. Every
  statement is idempotent (`IF NOT EXISTS` / guarded `DO $$` block /
  `COMMENT`), so it is safe to replay on an install where core already created
  the tables and on one with none of them.

  V1 order: every `CREATE TABLE`, then every constraint guard (primary keys,
  then foreign keys, then the CHECKs), then every index, then the version
  marker last.

  `target` selects how much of the chain to emit (default `current_version/0`);
  the wrapper migration core's update task generates passes an explicit
  `:version`, and a stale wrapper asking for an older version must not receive
  a newer version's objects.
  """
  @spec up_statements(String.t(), pos_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 1 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."
    target = min(target, @current_version)

    List.flatten([
      v1_statements(prefix, p),
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"
    ])
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)
      when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  # ── V1: adoption of the tables core's chain creates ─────────────────────

  defp v1_statements(prefix, p) do
    [tables(p), constraints(prefix, p), indexes(p)]
  end

  # Columns, types, defaults and order as core's V141 creates them.
  defp tables(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_calendar_events (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "owner_uuid" uuid NOT NULL,
        "title" character varying(255) NOT NULL,
        "description" text,
        "location" character varying(255),
        "all_day" boolean DEFAULT false NOT NULL,
        "starts_at" timestamp(0) without time zone,
        "ends_at" timestamp(0) without time zone,
        "starts_on" date,
        "ends_on" date,
        "color" character varying(50),
        "status" character varying(20) DEFAULT 'active'::character varying NOT NULL,
        "inserted_at" timestamp(0) without time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp(0) without time zone DEFAULT now() NOT NULL,
        "location_uuid" uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_calendar_event_participants (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "event_uuid" uuid NOT NULL,
        "kind" character varying(20) NOT NULL,
        "target_uuid" uuid,
        "display_name" character varying(255) NOT NULL,
        "added_by_uuid" uuid,
        "inserted_at" timestamp(0) without time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp(0) without time zone DEFAULT now() NOT NULL
      )
      """
    ]
  end

  # Core's V141 constraint names.
  defp constraints(prefix, p) do
    [
      guarded_constraint(
        prefix,
        "phoenix_kit_calendar_events",
        "phoenix_kit_calendar_events_pkey",
        "ALTER TABLE #{p}phoenix_kit_calendar_events ADD CONSTRAINT phoenix_kit_calendar_events_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_calendar_event_participants",
        "phoenix_kit_calendar_event_participants_pkey",
        "ALTER TABLE #{p}phoenix_kit_calendar_event_participants ADD CONSTRAINT phoenix_kit_calendar_event_participants_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_calendar_events",
        "phoenix_kit_calendar_events_owner_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_calendar_events ADD CONSTRAINT phoenix_kit_calendar_events_owner_uuid_fkey FOREIGN KEY (owner_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_calendar_event_participants",
        "phoenix_kit_calendar_event_participants_added_by_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_calendar_event_participants ADD CONSTRAINT phoenix_kit_calendar_event_participants_added_by_uuid_fkey FOREIGN KEY (added_by_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_calendar_event_participants",
        "phoenix_kit_calendar_event_participants_event_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_calendar_event_participants ADD CONSTRAINT phoenix_kit_calendar_event_participants_event_uuid_fkey FOREIGN KEY (event_uuid) REFERENCES #{p}phoenix_kit_calendar_events(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_calendar_events",
        "calendar_event_status",
        "ALTER TABLE #{p}phoenix_kit_calendar_events ADD CONSTRAINT calendar_event_status CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'cancelled'::character varying])::text[])))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_calendar_events",
        "calendar_event_time_shape",
        "ALTER TABLE #{p}phoenix_kit_calendar_events ADD CONSTRAINT calendar_event_time_shape CHECK ((((all_day = false) AND (starts_at IS NOT NULL) AND (ends_at IS NOT NULL) AND (starts_on IS NULL) AND (ends_on IS NULL) AND (ends_at > starts_at)) OR ((all_day = true) AND (starts_on IS NOT NULL) AND (ends_on IS NOT NULL) AND (starts_at IS NULL) AND (ends_at IS NULL) AND (ends_on > starts_on))))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_calendar_event_participants",
        "calendar_participant_kind",
        "ALTER TABLE #{p}phoenix_kit_calendar_event_participants ADD CONSTRAINT calendar_participant_kind CHECK (((kind)::text = ANY ((ARRAY['user'::character varying, 'staff_person'::character varying, 'crm_contact'::character varying, 'crm_company'::character varying, 'free_text'::character varying])::text[])))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_calendar_event_participants",
        "calendar_participant_shape",
        "ALTER TABLE #{p}phoenix_kit_calendar_event_participants ADD CONSTRAINT calendar_participant_shape CHECK (((((kind)::text = 'free_text'::text) AND (target_uuid IS NULL)) OR (((kind)::text <> 'free_text'::text) AND (target_uuid IS NOT NULL))))"
      )
    ]
  end

  # Index names are core's. They stay bare on CREATE (an index lives in its
  # table's schema).
  defp indexes(p) do
    [
      "CREATE INDEX IF NOT EXISTS idx_calendar_events_owner_starts_at ON #{p}phoenix_kit_calendar_events USING btree (owner_uuid, starts_at)",
      "CREATE INDEX IF NOT EXISTS idx_calendar_events_owner_starts_on ON #{p}phoenix_kit_calendar_events USING btree (owner_uuid, starts_on)",
      "CREATE INDEX IF NOT EXISTS idx_calendar_participants_event ON #{p}phoenix_kit_calendar_event_participants USING btree (event_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_participants_free_text ON #{p}phoenix_kit_calendar_event_participants USING btree (event_uuid, lower((display_name)::text)) WHERE ((kind)::text = 'free_text'::text)",
      "CREATE INDEX IF NOT EXISTS idx_calendar_participants_kind_target ON #{p}phoenix_kit_calendar_event_participants USING btree (kind, target_uuid) WHERE (target_uuid IS NOT NULL)",
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_participants_target ON #{p}phoenix_kit_calendar_event_participants USING btree (event_uuid, kind, target_uuid) WHERE (target_uuid IS NOT NULL)"
    ]
  end

  defp guarded_constraint(prefix, table, constraint_name, add_sql) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        #{add_sql};
      END IF;
    END
    $$
    """
  end

  defp marker_query do
    """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """
  end

  defp marker_to_version([@marker_prefix <> n]) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp marker_to_version(_), do: 0

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL and into the guard blocks' string literals.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
