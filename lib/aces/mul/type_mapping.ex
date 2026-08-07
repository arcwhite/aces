defmodule Aces.MUL.TypeMapping do
  @moduledoc """
  Single source of truth for the mapping between MUL API unit types and Aces'
  internal `unit_type` values.

  Two directions:

    * `to_mul_ids/1` — request direction. Given an internal `unit_type` (or a
      shorthand alias like `"mech"`), returns the MUL `Types` ids to send to
      QuickList. Returns a list because the collapse (see below) means one
      internal value may one day need more than one MUL id.

    * `resolve/2` — response direction. Given the MUL `Type` field and the
      `BFType` field from a QuickList payload, returns the internal
      `unit_type`. **BFType is consulted first**: it is the Alpha Strike
      statblock's own unit-type field and is more specific than `Type.Id`
      (`Type.Id 21` covers both Battle Armor and Conventional Infantry —
      only BFType tells them apart).

  ## The collapse

  Several distinct MUL categories collapse to a single internal `unit_type`.
  Callers that need the finer distinction should read `bf_type` off the
  cached `MasterUnit` directly.

  | BFType | Alpha Strike type       | internal `unit_type`               |
  |--------|-------------------------|------------------------------------|
  | `BM`   | BattleMech              | `battlemech`                       |
  | `IM`   | IndustrialMech          | `battlemech` *(collapsed)*         |
  | `PM`   | ProtoMech               | `protomech`                        |
  | `CV`   | Combat Vehicle          | `combat_vehicle`                   |
  | `SV`   | Support Vehicle         | `combat_vehicle` *(collapsed)*     |
  | `BA`   | Battle Armor            | `battle_armor`                     |
  | `CI`   | Conventional Infantry   | `conventional_infantry`            |
  | aero / large craft (`AF`, `CF`, `SC`, `DS`, `DA`, `JS`, `WS`, `SS`, `MS`) | — | `other` |

  Treat this list as *expected*, not exhaustive. Unknown pairs fall through
  to `"other"` and are logged so new values surface instead of silently
  bucketing.
  """

  require Logger

  # Internal type → MUL Types ids for the QuickList request. Aliases like
  # "mech" / "vehicle" resolve the same way as their canonical form; the
  # `infantry` keyword returns MUL type 21 which contains both BA and CI.
  @internal_to_mul_ids %{
    "battlemech" => [18],
    "mech" => [18],
    "combat_vehicle" => [19],
    "vehicle" => [19],
    "protomech" => [20],
    "infantry" => [21],
    "battle_armor" => [21],
    "conventional_infantry" => [21]
  }

  # BFType → internal `unit_type`. Case-insensitive lookup: live data mixes
  # "BA" and "ba".
  @bf_type_to_internal %{
    "bm" => "battlemech",
    "im" => "battlemech",
    "pm" => "protomech",
    "cv" => "combat_vehicle",
    "sv" => "combat_vehicle",
    "ba" => "battle_armor",
    "ci" => "conventional_infantry",
    "af" => "other",
    "cf" => "other",
    "sc" => "other",
    "ds" => "other",
    "da" => "other",
    "js" => "other",
    "ws" => "other",
    "ss" => "other",
    "ms" => "other"
  }

  # Fallback when BFType is missing/unknown. Aligned with the modal's
  # supported types (18/19/20); 21 is deliberately absent because it needs
  # BFType to split BA vs CI, so a bare Type.Id-21 with no BFType is
  # unclassifiable and returns "other" (logged).
  @type_id_to_internal %{
    18 => "battlemech",
    19 => "combat_vehicle",
    20 => "protomech"
  }

  # Type.Name → same internal codes. Preserved for the small number of MUL
  # payloads that omit `Type.Id` and only include a name.
  @type_name_to_internal %{
    "battlemech" => "battlemech",
    "mech" => "battlemech",
    "mechs" => "battlemech",
    "battlemechs" => "battlemech",
    "combat vehicle" => "combat_vehicle",
    "protomech" => "protomech",
    "battle armor" => "battle_armor"
  }

  # Modal-supported MUL Types ids. Matrix seeder and release.ex use this.
  @supported_mul_type_ids [18, 19, 20, 21]

  @doc """
  Returns the MUL `Types` ids for an internal `unit_type` (or shorthand alias).

  Returns `[]` for an unknown value so callers can treat "no mapping" as
  "no type filter to add" without a `nil` check.
  """
  @spec to_mul_ids(String.t() | nil) :: [integer()]
  def to_mul_ids(nil), do: []

  def to_mul_ids(type) when is_binary(type) do
    Map.get(@internal_to_mul_ids, String.downcase(type), [])
  end

  @doc """
  Returns the MUL type ids the unit-search modal supports (18/19/20/21).

  Used by matrix mode and by `Aces.Release` to pin the type filter to the
  set Aces actually renders in the UI.
  """
  @spec supported_mul_type_ids() :: [integer()]
  def supported_mul_type_ids, do: @supported_mul_type_ids

  @doc """
  Returns the expected BFType codes (uppercase) — the set the resolver knows
  how to bucket. Anything cached with a BFType outside this set is either a
  new MUL value or malformed data, and should surface in the matrix seed
  histogram so it isn't silently ignored.
  """
  @spec known_bf_types() :: [String.t()]
  def known_bf_types do
    @bf_type_to_internal
    |> Map.keys()
    |> Enum.map(&String.upcase/1)
  end

  @doc """
  Resolves a QuickList payload's `Type` + `BFType` into an internal
  `unit_type`.

  Resolution order:

    1. `BFType` if present and known (case-insensitive).
    2. `Type.Id` from the fallback table (18/19/20).
    3. `Type.Name` for payloads missing `Id`.
    4. `"other"` — and a `Logger.info` naming the unrecognised pair so we
       can spot new values in the wild.
  """
  @spec resolve(map() | String.t() | nil, String.t() | nil) :: String.t()
  def resolve(type_field, bf_type) do
    case resolve_by_bf_type(bf_type) do
      {:ok, unit_type} ->
        unit_type

      :unknown ->
        case resolve_by_type_field(type_field) do
          {:ok, unit_type} ->
            unit_type

          :unknown ->
            Logger.info(
              "MUL.TypeMapping: unrecognised unit classification " <>
                "Type=#{inspect(type_field)} BFType=#{inspect(bf_type)} — falling back to \"other\""
            )

            "other"
        end
    end
  end

  defp resolve_by_bf_type(bf_type) when is_binary(bf_type) do
    case Map.fetch(@bf_type_to_internal, String.downcase(bf_type)) do
      {:ok, unit_type} -> {:ok, unit_type}
      :error -> :unknown
    end
  end

  defp resolve_by_bf_type(_), do: :unknown

  defp resolve_by_type_field(%{"Id" => id}) when is_map_key(@type_id_to_internal, id) do
    {:ok, Map.fetch!(@type_id_to_internal, id)}
  end

  defp resolve_by_type_field(%{"Name" => name}) when is_binary(name) do
    resolve_by_type_name(name)
  end

  defp resolve_by_type_field(name) when is_binary(name), do: resolve_by_type_name(name)

  defp resolve_by_type_field(_), do: :unknown

  defp resolve_by_type_name(name) do
    case Map.fetch(@type_name_to_internal, String.downcase(name)) do
      {:ok, unit_type} -> {:ok, unit_type}
      :error -> :unknown
    end
  end
end
