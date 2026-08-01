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
  alias Aces.Units.Filters
  alias Aces.Units.MasterUnit
  alias Aces.MUL.Client

  require Logger

  @cache_ttl_days 30  # Refresh cached units after 30 days

  @doc """
  Search for units — checks local DB first, falls back to the MUL client.

  Returns a typed result identifying where the units came from:

    * `{:ok, {units, :local}}` — local cache satisfied the query.
    * `{:ok, {units, :api | :fixture}}` — fell through to `Aces.MUL.Client`,
      whose configured source populated the result (see the client's
      `mul_client_source` config).
    * `{:error, {:term_too_short, _}}` — search terms shorter than 2 chars
      are refused up-front rather than silently returning `[]`.
    * `{:error, {:mul_unavailable, reason}}` — MUL was unreachable.
    * `{:error, {:query_failed, reason}}` — MUL rejected the query, or a
      local DB failure was caught here.

  Callers that only care about the unit list can wrap this in a `with`.
  """
  def search_units(search_term, opts \\ []) when is_binary(search_term) do
    search_term = String.trim(search_term)

    if String.length(search_term) < 2 do
      {:error, {:term_too_short, search_term}}
    else
      try do
        local_results = search_local_units(search_term, opts)

        if length(local_results) > 0 do
          {:ok, {local_results, :local}}
        else
          search_and_cache_from_api(search_term, opts)
        end
      rescue
        error ->
          Logger.error("Local unit search failed for '#{search_term}': #{inspect(error)}")
          {:error, {:query_failed, {:local_search_raised, error.__struct__}}}
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
    |> Filters.filter(opts)
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
    |> Filters.filter(opts)
    |> order_by([u], u.name)
    |> limit(50)
    |> Repo.all()
  end

  defp search_and_cache_from_api(search_term, opts) do
    # Convert internal filter format to Client-compatible format
    api_filters = translate_filters_for_api(opts)
    filters = Map.put(api_filters, :name, search_term)

    case Client.fetch_units(filters) do
      {:ok, {api_units, source}} ->
        cached_units =
          api_units
          |> Enum.map(&create_or_update_master_unit/1)
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, unit} -> unit end)

        {:ok, {cached_units, source}}

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

  @doc """
  Search for units with user-friendly filter format.

  This function is designed for use in LiveViews and contexts that need
  simple, user-facing filter options with comprehensive error handling.

  ## Parameters

    * `search_term` - The text to search for (minimum 2 characters)
    * `filters` - Map with user-friendly keys:
      * `:eras` - List of era strings (e.g., ["ilclan", "dark_age"])
      * `:faction` - Faction string (e.g., "mercenary", "clan_wolf")
      * `:type` - Unit type string (e.g., "battlemech", "combat_vehicle")

  ## Returns

    * `{:ok, {units, source}}` — `source` is `:local`, `:api`, or `:fixture`,
      identifying where the units came from so callers can surface it.
    * `{:error, :term_too_short}` — search term below 2 characters.
    * `{:error, {:mul_unavailable, reason}}` — MUL unreachable / rate-limited.
    * `{:error, {:query_failed, reason}}` — MUL rejected the query or a local
      DB failure was caught.

  ## Examples

      iex> search_units_for_company("Atlas", %{eras: ["ilclan"], faction: "mercenary"})
      {:ok, {[%MasterUnit{name: "Atlas", ...}, ...], :local}}

      iex> search_units_for_company("A", %{})
      {:error, :term_too_short}
  """
  def search_units_for_company(search_term, filters \\ %{}) when is_binary(search_term) do
    search_term = String.trim(search_term)

    if String.length(search_term) < 2 do
      {:error, :term_too_short}
    else
      opts = build_search_opts_from_filters(filters)

      case search_units(search_term, opts) do
        {:ok, {units, source}} ->
          {:ok, {units, source}}

        {:error, {:term_too_short, _}} ->
          {:error, :term_too_short}

        {:error, _typed} = err ->
          err
      end
    end
  end

  # Convert user-friendly filter format to internal opts format
  defp build_search_opts_from_filters(filters) when is_map(filters) do
    opts = []

    # Add unit type filter if set
    opts =
      case Map.get(filters, :type) do
        nil -> opts
        type -> [{:unit_type, type} | opts]
      end

    # Add era + faction filter if both are set
    opts =
      case {Map.get(filters, :eras), Map.get(filters, :faction)} do
        {eras, faction} when is_list(eras) and length(eras) > 0 and is_binary(faction) ->
          [{:era_faction, {eras, faction}} | opts]

        _ ->
          opts
      end

    opts
  end

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