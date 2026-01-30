defmodule Aces.Units do
  @moduledoc """
  Context for managing unit data (master units and company units)

  Implements a hybrid caching approach:
  1. Check local database first
  2. Fall back to MUL API if not found
  3. Cache API responses in database
  """

  import Ecto.Query
  alias Aces.Repo
  alias Aces.Units.MasterUnit
  alias Aces.MUL.Client

  require Logger

  @cache_ttl_days 30  # Refresh cached units after 30 days

  @doc """
  Search for units - checks local DB first, falls back to API

  ## Examples

      iex> search_units("Atlas")
      [%MasterUnit{name: "Atlas", variant: "AS7-D"}, ...]
  """
  def search_units(search_term, opts \\ []) when is_binary(search_term) do
    search_term = String.trim(search_term)

    if String.length(search_term) < 2 do
      []
    else
      local_results = search_local_units(search_term, opts)

      # If we have recent local results, return them
      if length(local_results) > 0 do
        local_results
      else
        # Try API as fallback
        case search_and_cache_from_api(search_term, opts) do
          {:ok, units} -> units
          {:error, reason} ->
            Logger.info("MUL API search failed for '#{search_term}': #{reason}")
            []  # Graceful degradation
        end
      end
    end
  end

  @doc """
  Get unit by MUL ID - checks cache first, then API
  """
  def get_master_unit_by_mul_id(mul_id) when is_integer(mul_id) do
    case Repo.get_by(MasterUnit, mul_id: mul_id) do
      nil ->
        # Not in cache, fetch from API
        fetch_and_cache_unit(mul_id)

      unit ->
        # Check if cache is stale
        if cache_stale?(unit) do
          refresh_unit_from_api(unit)
        else
          {:ok, unit}
        end
    end
  end

  @doc """
  Get all master units from local cache

  This is useful for offline scenarios or when you want to
  avoid API calls entirely.
  """
  def list_cached_master_units(opts \\ []) do
    MasterUnit
    |> apply_filters(opts)
    |> order_by([u], u.name)
    |> Repo.all()
  end

  @doc """
  Create or update a master unit from API data.

  When updating an existing unit, the factions field is merged rather than replaced,
  allowing faction availability to accumulate across multiple seed operations with
  different era/faction combinations.
  """
  def create_or_update_master_unit(attrs) when is_map(attrs) do
    case Repo.get_by(MasterUnit, mul_id: attrs[:mul_id] || attrs["mul_id"]) do
      nil ->
        %MasterUnit{}
        |> MasterUnit.changeset(attrs)
        |> Repo.insert()

      existing ->
        # Merge factions instead of replacing
        merged_attrs = merge_faction_attrs(existing, attrs)

        existing
        |> MasterUnit.changeset(merged_attrs)
        |> Repo.update()
    end
  end

  # Merge new faction data with existing faction data
  defp merge_faction_attrs(existing, attrs) do
    new_factions = attrs[:factions] || attrs["factions"] || %{}
    existing_factions = existing.factions || %{}

    # Merge each era's faction list
    merged_factions =
      Enum.reduce(new_factions, existing_factions, fn {era, faction_list}, acc ->
        MasterUnit.merge_factions(acc, era, faction_list)
      end)

    Map.put(attrs, :factions, merged_factions)
  end

  @doc """
  Returns the total count of cached units
  """
  def count_cached_units do
    Repo.aggregate(MasterUnit, :count)
  end

  # Private functions

  defp search_local_units(search_term, opts) do
    ilike_term = "%#{search_term}%"

    MasterUnit
    |> where([u], ilike(u.name, ^ilike_term) or
                   ilike(u.variant, ^ilike_term) or
                   ilike(u.full_name, ^ilike_term))
    |> apply_filters(opts)
    |> order_by([u], u.name)
    |> limit(50)
    |> Repo.all()
  end

  defp search_and_cache_from_api(search_term, opts) do
    # Convert internal filter format to Client-compatible format
    api_filters = translate_filters_for_api(opts)
    filters = Map.put(api_filters, :name, search_term)

    case Client.fetch_units(filters) do
      {:ok, api_units} ->
        cached_units =
          api_units
          |> Enum.map(&create_or_update_master_unit/1)
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, unit} -> unit end)

        {:ok, cached_units}

      error -> error
    end
  end

  # Translate internal filter format to MUL API format
  defp translate_filters_for_api(opts) do
    Enum.reduce(opts, %{}, fn
      {:era_faction, {eras, faction}}, acc ->
        # Convert era_faction tuple to separate eras and factions filters
        acc
        |> Map.put(:eras, eras)
        |> Map.put(:factions, [faction])

      {:unit_type, type}, acc ->
        # Pass through unit_type as-is (Client handles it)
        Map.put(acc, :unit_type, type)

      {key, value}, acc ->
        # Pass through other filters
        Map.put(acc, key, value)
    end)
  end

  defp fetch_and_cache_unit(_mul_id) do
    # Cannot fetch by MUL ID alone - the MUL API requires a name search
    # Units should be added through search_units which uses the QuickList API
    {:error, :not_found}
  end

  defp cache_stale?(unit) do
    if unit.last_synced_at do
      days_since_sync = DateTime.diff(DateTime.utc_now(), unit.last_synced_at, :day)
      days_since_sync > @cache_ttl_days
    else
      true
    end
  end

  defp refresh_unit_from_api(unit) do
    case Client.fetch_unit(unit.mul_id, unit.full_name) do
      {:ok, fresh_data} ->
        unit
        |> MasterUnit.changeset(fresh_data)
        |> Repo.update()

      {:error, _} ->
        # API failed, return stale data
        {:ok, unit}
    end
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:unit_type, type} | rest]) do
    query
    |> where([u], u.unit_type == ^type)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:min_pv, min} | rest]) do
    query
    |> where([u], u.point_value >= ^min)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:max_pv, max} | rest]) do
    query
    |> where([u], u.point_value <= ^max)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:tonnage_range, {min, max}} | rest]) do
    query
    |> where([u], u.tonnage >= ^min and u.tonnage <= ^max)
    |> apply_filters(rest)
  end

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

  defp apply_filters(query, [{:era, era} | rest]) when is_binary(era) do
    case Map.get(@era_ids, era) do
      nil ->
        apply_filters(query, rest)

      era_id ->
        query
        |> where([u], u.era_id == ^era_id)
        |> apply_filters(rest)
    end
  end

  defp apply_filters(query, [{:faction, faction} | rest]) when is_binary(faction) do
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
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:factions, factions} | rest]) when is_list(factions) do
    # Check if unit is available to any of the specified factions (legacy)
    lowercase_factions = Enum.map(factions, &String.downcase/1)

    query
    |> where([u], fragment("? \\?| ?", u.factions, ^lowercase_factions))
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:era_faction, {eras, faction}} | rest])
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
    |> apply_filters(rest)
  end

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)

  @doc """
  Lists all variants of a given chassis (same name, different variants).
  Used for OMNI mech reconfiguration.

  Returns a list of master units with the same name, ordered by variant.
  """
  def list_variants_for_chassis(%MasterUnit{name: name}) do
    MasterUnit
    |> where([u], u.name == ^name)
    |> order_by([u], u.variant)
    |> Repo.all()
  end

  def list_variants_for_chassis(name) when is_binary(name) do
    MasterUnit
    |> where([u], u.name == ^name)
    |> order_by([u], u.variant)
    |> Repo.all()
  end

  @doc """
  Check if a master unit has the OMNI special ability.
  """
  def is_omni?(%MasterUnit{bf_abilities: nil}), do: false
  def is_omni?(%MasterUnit{bf_abilities: ""}), do: false
  def is_omni?(%MasterUnit{bf_abilities: abilities}) do
    # OMNI appears as "OMNI" in comma-separated abilities (no space after comma)
    abilities
    |> String.split(",")
    |> Enum.any?(fn ability -> String.starts_with?(ability, "OMNI") end)
  end

  @doc """
  Refresh units that are missing bf_size from the MUL API.

  Options:
    - limit: Maximum number of units to refresh (default: all)

  Returns {:ok, count} with the number of units updated.
  """
  def refresh_units_missing_bf_size(opts \\ []) do
    limit = Keyword.get(opts, :limit, nil)

    query = MasterUnit |> where([u], is_nil(u.bf_size))
    query = if limit, do: query |> limit(^limit), else: query

    units_to_refresh = Repo.all(query)

    Logger.info("Refreshing #{length(units_to_refresh)} units missing bf_size")

    updated_count =
      units_to_refresh
      |> Enum.map(fn unit ->
        case Client.fetch_unit(unit.mul_id, unit.full_name) do
          {:ok, fresh_data} ->
            unit
            |> MasterUnit.changeset(fresh_data)
            |> Repo.update()

          {:error, reason} ->
            Logger.warning("Failed to refresh unit #{unit.mul_id} (#{unit.full_name}): #{inspect(reason)}")
            {:error, reason}
        end
      end)
      |> Enum.count(&match?({:ok, _}, &1))

    Logger.info("Successfully refreshed #{updated_count} units with bf_size")
    {:ok, updated_count}
  end
end