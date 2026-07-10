defmodule PhoenixKitCalendar.Participants do
  @moduledoc """
  Attaching people to calendar events.

  ## Authorization

  Editing an event's participants requires edit access to the event
  (`PhoenixKitCalendar.Events.can_edit?/2` semantics). Per-KIND gating on
  top (quorum-hardened, and validated HERE — never only in the UI):

  | kind | requires |
  |------|----------|
  | `user` | `calendar.invite_platform_users` |
  | `staff_person` | `calendar.invite_staff` + staff module enabled |
  | `crm_contact` / `crm_company` | `calendar.invite_crm` + CRM module enabled |
  | `free_text` | nothing beyond event edit access |

  ## Replace semantics

  `replace_participants/3` is a full-replace-with-diff inside one
  transaction: rows not in the new set are deleted (visibility revoked
  immediately), new entries are inserted, unchanged rows are kept
  untouched. Only NEWLY added entries notify — each is live-resolved to a
  platform user (`PhoenixKitCalendar.Sources.resolve_user/1`) and logged
  with `target_uuid`, which core's notification system fans out to an
  in-app notification. Company adds create no per-member notifications
  (members see the event via live visibility instead).
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKitCalendar.Events
  alias PhoenixKitCalendar.Schemas.Event
  alias PhoenixKitCalendar.Schemas.Participant
  alias PhoenixKitCalendar.Sources

  @doc """
  Lists an event's participants (insertion order), authorized against the
  event's persisted owner. Returns `[]` unless the scope may read the event
  (owner-view or participant, module enabled) — so this public read honors
  the same boundary as `Events.get_event/2` and can't be used to enumerate a
  disabled module's participants.
  """
  @spec list_for_event(Scope.t() | nil, Event.t()) :: [Participant.t()]
  def list_for_event(scope, %Event{} = event) do
    if Events.readable?(scope, event) do
      raw_list_for_event(event.uuid)
    else
      []
    end
  end

  # Unscoped raw read — internal only (replace_participants already
  # authorized + locked the event). NEVER expose this.
  defp raw_list_for_event(event_uuid) do
    from(p in Participant,
      where: p.event_uuid == ^event_uuid,
      order_by: [asc: p.inserted_at, asc: p.uuid]
    )
    |> repo().all()
  end

  @doc """
  Replaces the event's participant set with `entries`
  (`[%{kind, target_uuid, display_name}]`), diffing against the current
  rows. Returns `{:ok, participants}` or `{:error, :unauthorized}` /
  `{:error, changeset}`.

  Authorization: event edit access, plus the per-kind invite permission
  for every NEWLY ADDED entry (existing rows of a kind the editor can't
  grant are preserved — an editor without `invite_crm` can't add clients
  but doesn't silently strip someone else's).
  """
  @spec replace_participants(Scope.t() | nil, Event.t(), [map()]) ::
          {:ok, [Participant.t()]}
          | {:error, :unauthorized | :invalid_participant | Ecto.Changeset.t()}
  def replace_participants(scope, %Event{} = event, entries) do
    entries = normalize_entries(entries)

    # Everything runs inside ONE transaction that first LOCKS the event row.
    # This (a) authorizes the event's PERSISTED owner — not the caller's
    # in-memory struct, which could carry a forged owner_uuid — and (b)
    # computes the current set + diff under the lock, so two concurrent
    # replacements can't both read the same state and leave their union.
    result =
      repo().transaction(fn ->
        fresh = lock_event(event.uuid)

        cond do
          is_nil(fresh) ->
            repo().rollback(:not_found)

          not Events.can_edit?(scope, fresh.owner_uuid) ->
            repo().rollback(:unauthorized)

          true ->
            apply_replace(scope, fresh, entries)
        end
      end)

    case result do
      {:ok, {list, added}} ->
        # notify AFTER commit — never hold the txn open on external work
        notify_added(scope, event, added)
        {:ok, list}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Diff + mutate under the event-row lock. Returns {participant_list,
  # canonicalized_added} for post-commit notification.
  defp apply_replace(scope, %Event{} = event, entries) do
    current = raw_list_for_event(event.uuid)
    current_keys = MapSet.new(current, &entry_key/1)
    desired_keys = MapSet.new(entries, &entry_key/1)

    added = Enum.filter(entries, &(not MapSet.member?(current_keys, entry_key(&1))))
    removed = Enum.filter(current, &(not MapSet.member?(desired_keys, entry_key(&1))))

    unless Enum.all?(added, &kind_allowed?(scope, &1.kind)) do
      repo().rollback(:unauthorized)
    end

    added =
      case canonicalize_added(added) do
        {:ok, canonical} -> canonical
        :error -> repo().rollback(:invalid_participant)
      end

    if removed != [] do
      removed_uuids = Enum.map(removed, & &1.uuid)
      from(p in Participant, where: p.uuid in ^removed_uuids) |> repo().delete_all()
    end

    added_by = scope && Scope.user_uuid(scope)
    Enum.each(added, &insert_participant!(event, &1, added_by))

    {raw_list_for_event(event.uuid), added}
  end

  # Locks the event row FOR UPDATE (serializes concurrent replacements) and
  # returns the fresh struct, or nil if it was deleted meanwhile.
  defp lock_event(event_uuid) do
    from(e in Event, where: e.uuid == ^event_uuid, lock: "FOR UPDATE")
    |> repo().one()
  end

  # Server-side identity resolution (quorum HIGH finding): the persisted
  # display_name comes from the SOURCE TABLE, never from the client, and a
  # target that doesn't exist (or is soft-deleted) rejects the save — no
  # spoofed labels, no uuid probing, no garbage rows.
  defp canonicalize_added(added) do
    added
    |> Enum.reduce_while([], fn entry, acc ->
      case canonicalize_entry(entry) do
        {:ok, entry} -> {:cont, [entry | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      entries -> {:ok, Enum.reverse(entries)}
    end
  end

  defp canonicalize_entry(%{kind: "free_text"} = entry), do: {:ok, %{entry | target_uuid: nil}}

  defp canonicalize_entry(entry) do
    case Sources.canonical_name(entry.kind, entry.target_uuid) do
      {:ok, name} -> {:ok, %{entry | display_name: name}}
      :error -> :error
    end
  end

  @doc """
  Whether the scope may add participants of the given kind at all —
  drives which picker sources the UI offers (the context re-validates on
  save regardless).
  """
  @spec kind_allowed?(Scope.t() | nil, String.t()) :: boolean()
  def kind_allowed?(_scope, "free_text"), do: true
  def kind_allowed?(scope, "user"), do: Scope.can?(scope, "calendar.invite_platform_users")

  # the invite permission COMPOSES with the source module's enablement —
  # same rule the UI applies, enforced here so a forged event can't add
  # staff/CRM kinds while those modules are disabled
  def kind_allowed?(scope, "staff_person"),
    do: Scope.can?(scope, "calendar.invite_staff") and Permissions.feature_enabled?("staff")

  def kind_allowed?(scope, kind) when kind in ["crm_contact", "crm_company"],
    do: Scope.can?(scope, "calendar.invite_crm") and Permissions.feature_enabled?("crm")

  def kind_allowed?(_scope, _kind), do: false

  # ===========================================================================

  # Inserts one participant row or rolls the surrounding transaction back.
  defp insert_participant!(event, entry, added_by) do
    %Participant{}
    |> Participant.changeset(%{
      event_uuid: event.uuid,
      kind: entry.kind,
      target_uuid: entry.target_uuid,
      display_name: entry.display_name,
      added_by_uuid: added_by
    })
    |> repo().insert()
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  # Only newly added, directly-resolvable people are notified; skips the
  # actor adding themselves. Guarded — a logging failure never breaks the
  # save.
  defp notify_added(scope, event, added) do
    actor_uuid = scope && Scope.user_uuid(scope)

    if Code.ensure_loaded?(PhoenixKit.Activity) do
      Enum.each(added, &log_participant_added(event, &1, actor_uuid))
    end
  rescue
    _ -> :ok
  end

  defp log_participant_added(event, entry, actor_uuid) do
    target = Sources.resolve_user(entry)

    if is_binary(target) and target != actor_uuid do
      PhoenixKit.Activity.log(%{
        action: "calendar_event.participant_added",
        module: "calendar",
        mode: "manual",
        actor_uuid: actor_uuid,
        resource_type: "calendar_event",
        resource_uuid: event.uuid,
        target_uuid: target,
        # No event TITLE here — the activity feed is readable beyond calendar
        # permissions (see Events.tap_log/4). The participant sees the full
        # event (title and all) on their OWN calendar via live visibility, so
        # a title-free notification leaks nothing yet still points them there.
        metadata: %{
          "notification_text" => notification_text()
        }
      })
    end
  end

  defp notification_text do
    Gettext.gettext(
      PhoenixKitWeb.Gettext,
      "You were added to an event — it's now on your calendar"
    )
  end

  defp normalize_entries(entries) do
    entries
    |> Enum.map(fn entry ->
      %{
        kind: to_string(entry[:kind] || entry["kind"] || ""),
        target_uuid: entry[:target_uuid] || entry["target_uuid"],
        display_name: String.trim(to_string(entry[:display_name] || entry["display_name"] || ""))
      }
    end)
    |> Enum.filter(&(&1.kind in Participant.kinds() and &1.display_name != ""))
    |> Enum.uniq_by(&entry_key/1)
  end

  # free_text rows key on the lowercased name (mirrors the partial unique);
  # targeted rows key on kind+target.
  defp entry_key(%{kind: "free_text", display_name: name}),
    do: {"free_text", String.downcase(name)}

  defp entry_key(%{kind: kind, target_uuid: target}), do: {kind, to_string(target)}

  defp repo, do: RepoHelper.repo()
end
