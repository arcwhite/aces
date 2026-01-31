defmodule Aces.Units.Filters do
  @moduledoc """
  Query filters for master units.

  This module provides composable filters for querying the master_units table.
  Filters are applied as a keyword list and processed recursively.

  ## Supported Filters

  ### Unit Type
    * `{:unit_type, type}` - Filter by unit type (e.g., "BattleMech", "Combat Vehicle")

  ### Point Value
    * `{:min_pv, integer}` - Minimum point value (inclusive)
    * `{:max_pv, integer}` - Maximum point value (inclusive)

  ### Tonnage
    * `{:tonnage_range, {min, max}}` - Filter by tonnage range (inclusive)

  ### Era
    * `{:era, era_string}` - Filter by unit introduction era

    Supported era strings:
      - "ilclan" (3151+)
      - "dark_age"
      - "late_republic" / "republic"
      - "early_republic"
      - "jihad"
      - "civil_war"
      - "clan_invasion"
      - "late_succession_war"
      - "early_succession_war"
      - "star_league"

  ### Faction Availability
    * `{:faction, faction_string}` - Filter by faction availability (legacy format)
      Checks both old top-level format and new era-based format.

    * `{:factions, [faction_strings]}` - Filter by any of multiple factions (legacy)
      Returns units available to any faction in the list.

    * `{:era_faction, {eras, faction}}` - Era-aware faction filter (preferred)
      Filters for units available to a faction in any of the specified eras.
      Example: `{:era_faction, {["ilclan", "dark_age"], "mercenary"}}`

  ## Usage

      import Ecto.Query
      alias Aces.Units.Filters

      MasterUnit
      |> Filters.apply(unit_type: "BattleMech", min_pv: 20, max_pv: 50)
      |> Repo.all()

  Unknown filter keys are silently ignored, allowing forward compatibility.
  """

  import Ecto.Query

  # Era ID mapping for filtering by unit introduction era
  # Note: This filters by when the unit was INTRODUCED, not faction availability
  @era_ids %{
    "ilclan" => 257,
    "dark_age" => 16,
    "late_republic" => 254,
    "republic" => 254,
    "early_republic" => 15,
    "jihad" => 14,
    "civil_war" => 247,
    "clan_invasion" => 13,
    "late_succession_war" => 256,
    "early_succession_war" => 11,
    "star_league" => 10
  }

  @doc """
  Apply a list of filters to a query.

  Filters are processed recursively, with each filter adding a WHERE clause
  to the query. Unknown filters are ignored.

  ## Examples

      iex> Filters.filter(MasterUnit, unit_type: "BattleMech")
      #Ecto.Query<...>

      iex> Filters.filter(MasterUnit, min_pv: 20, max_pv: 50, era: "ilclan")
      #Ecto.Query<...>
  """
  @spec filter(Ecto.Queryable.t(), keyword()) :: Ecto.Query.t()
  def filter(query, []), do: query

  def filter(query, [{:unit_type, type} | rest]) do
    query
    |> where([u], u.unit_type == ^type)
    |> filter(rest)
  end

  def filter(query, [{:min_pv, min} | rest]) do
    query
    |> where([u], u.point_value >= ^min)
    |> filter(rest)
  end

  def filter(query, [{:max_pv, max} | rest]) do
    query
    |> where([u], u.point_value <= ^max)
    |> filter(rest)
  end

  def filter(query, [{:tonnage_range, {min, max}} | rest]) do
    query
    |> where([u], u.tonnage >= ^min and u.tonnage <= ^max)
    |> filter(rest)
  end

  def filter(query, [{:era, era} | rest]) when is_binary(era) do
    case Map.get(@era_ids, era) do
      nil ->
        filter(query, rest)

      era_id ->
        query
        |> where([u], u.era_id == ^era_id)
        |> filter(rest)
    end
  end

  def filter(query, [{:faction, faction} | rest]) when is_binary(faction) do
    # Legacy filter - check if faction exists as a top-level key (old format)
    # or in any era's faction list (new format)
    lowercase_faction = String.downcase(faction)

    query
    |> where(
      [u],
      fragment(
        """
        (? \\? ?) OR
        EXISTS (
          SELECT 1 FROM jsonb_each(?) AS era_data
          WHERE era_data.value @> to_jsonb(?::text)
        )
        """,
        u.factions,
        ^lowercase_faction,
        u.factions,
        ^lowercase_faction
      )
    )
    |> filter(rest)
  end

  def filter(query, [{:factions, factions} | rest]) when is_list(factions) do
    # Check if unit is available to any of the specified factions (legacy)
    lowercase_factions = Enum.map(factions, &String.downcase/1)

    query
    |> where([u], fragment("? \\?| ?", u.factions, ^lowercase_factions))
    |> filter(rest)
  end

  def filter(query, [{:era_faction, {eras, faction}} | rest])
      when is_list(eras) and is_binary(faction) do
    # Era-aware faction filter: check if faction is available in ANY of the specified eras
    # New factions format: %{"ilclan" => ["mercenary", "capellan"], "dark_age" => ["mercenary"]}
    lowercase_faction = String.downcase(faction)

    query
    |> where(
      [u],
      fragment(
        """
        EXISTS (
          SELECT 1 FROM jsonb_each(?) AS era_data
          WHERE era_data.key = ANY(?)
          AND era_data.value @> to_jsonb(?::text)
        )
        """,
        u.factions,
        ^eras,
        ^lowercase_faction
      )
    )
    |> filter(rest)
  end

  # Catch-all: skip unknown filters for forward compatibility
  def filter(query, [_ | rest]), do: filter(query, rest)
end
