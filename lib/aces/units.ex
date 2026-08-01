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
  alias Aces.MUL.{Client, Vocabulary}

  require Logger

  @cache_ttl_days 30  # Refresh cached units after 30 days

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
  Get master units from local cache.

  Returns `{:ok, units}` on success, `{:error, {:query_failed, reason}}` if the
  DB call raises. Callers should pattern-match instead of rescuing at the view
  layer — the shape mirrors `search/2` so both boundary calls can be handled
  uniformly.

  In addition to the keys accepted by `Aces.Units.Filters`, `:limit` caps the
  returned row count (useful for populating default UI listings).
  """
  def list_cached_master_units(opts \\ []) do
    {limit, filter_opts} = Keyword.pop(opts, :limit)

    query =
      MasterUnit
      |> Filters.filter(filter_opts)
      |> order_by([u], u.name)

    query = if limit, do: limit(query, ^limit), else: query

    try do
      {:ok, Repo.all(query)}
    rescue
      error ->
        Logger.error("list_cached_master_units failed: #{inspect(error)}")
        {:error, {:query_failed, error}}
    end
  end

  @doc """
  Create or update a master unit from API data.

  When updating an existing unit, the factions field is merged rather than replaced,
  allowing faction availability to accumulate across multiple seed operations with
  different era/faction combinations.

  Returns `{:error, :no_alpha_strike_card}` for payloads that lack both `bf_type`
  and `point_value` — units without an Alpha Strike statline are not useful to
  cache and would otherwise fall through to `TypeMapping.resolve/2`'s `"other"`
  bucket.
  """
  def create_or_update_master_unit(attrs) when is_map(attrs) do
    case Repo.get_by(MasterUnit, mul_id: attrs[:mul_id] || attrs["mul_id"]) do
      nil ->
        if no_alpha_strike_card?(attrs) do
          {:error, :no_alpha_strike_card}
        else
          %MasterUnit{}
          |> MasterUnit.changeset(attrs)
          |> Repo.insert()
        end

      existing ->
        # Merge factions instead of replacing
        merged_attrs = merge_faction_attrs(existing, attrs)

        existing
        |> MasterUnit.changeset(merged_attrs)
        |> Repo.update()
    end
  end

  defp no_alpha_strike_card?(attrs) do
    is_nil(attrs[:bf_type] || attrs["bf_type"]) and
      is_nil(attrs[:point_value] || attrs["point_value"])
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

  @doc """
  Imports a batch of normalized unit maps into the local cache.

  Returns `%{successes: n, errors: n, skipped: n, errored: [{unit_data, changeset}]}`.
  `skipped` counts payloads rejected as cardless (see
  `create_or_update_master_unit/1`); `errored` carries the changeset for each
  validation failure so callers can log or format them.
  """
  def import_units(units) when is_list(units) do
    Enum.reduce(units, %{successes: 0, errors: 0, skipped: 0, errored: []}, fn unit_data, acc ->
      case create_or_update_master_unit(unit_data) do
        {:ok, _} ->
          %{acc | successes: acc.successes + 1}

        {:error, :no_alpha_strike_card} ->
          %{acc | skipped: acc.skipped + 1}

        {:error, changeset} ->
          %{acc | errors: acc.errors + 1, errored: [{unit_data, changeset} | acc.errored]}
      end
    end)
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
      {:ok, api_units} ->
        Enum.each(api_units, &create_or_update_master_unit/1)
        # Re-run the local pass with the full original opts so untranslatable
        # filters (dropped from the API request) still narrow the returned set.
        {:ok, search_local_units(search_term, opts)}

      error ->
        error
    end
  end

  # Internal opt keys that MUL binds. Anything not here is dropped from the
  # API request (with a debug log) and enforced by the local pass instead.
  @supported_filter_keys ~w(era eras era_faction unit_type min_pv max_pv tonnage_range)a

  @doc false
  # Translate internal filter opts into a best-effort MUL API narrowing request.
  # Unknown keys never fail the search — they just don't reach MUL. Public for
  # test visibility; not part of the API contract.
  def translate_filters_for_api(opts) do
    {known, unknown} = Enum.split_with(opts, fn {key, _} -> key in @supported_filter_keys end)

    if unknown != [] do
      Logger.debug(fn ->
        keys = unknown |> Enum.map(fn {k, _} -> k end) |> Enum.uniq()
        "MUL filter translation dropped unsupported keys: #{inspect(keys)}"
      end)
    end

    known
    |> Enum.reduce(%{}, &translate_filter/2)
    |> pair_complete(:min_pv, :max_pv, 0, 9999)
    |> pair_complete(:min_tons, :max_tons, 0, 200)
  end

  defp translate_filter({:era_faction, {eras, faction}}, acc) do
    acc
    |> Map.put(:eras, eras)
    |> Map.put(:factions, [faction])
  end

  defp translate_filter({:unit_type, type}, acc) do
    case Vocabulary.mul_type_id(type) do
      nil -> acc
      id -> Map.put(acc, :types, [id])
    end
  end

  defp translate_filter({:tonnage_range, {min, max}}, acc) do
    acc
    |> Map.put(:min_tons, min)
    |> Map.put(:max_tons, max)
  end

  defp translate_filter({key, value}, acc), do: Map.put(acc, key, value)

  # MUL ignores a lone bound in a range filter; emit the pair or neither, using
  # sentinels for the missing side (verified: MinPV=0&MaxPV=9999 is unfiltered).
  defp pair_complete(filters, min_key, max_key, min_default, max_default) do
    case {Map.has_key?(filters, min_key), Map.has_key?(filters, max_key)} do
      {true, false} -> Map.put(filters, max_key, max_default)
      {false, true} -> Map.put(filters, min_key, min_default)
      _ -> filters
    end
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

  Checks local DB first and falls back to the MUL API for cache misses.
  Designed for use in LiveViews and contexts that need simple, user-facing
  filter options with comprehensive error handling.

  ## Parameters

    * `search_term` - The text to search for (minimum 2 characters)
    * `filters` - Map with user-friendly keys:
      * `:eras` - List of era strings (e.g., ["ilclan", "dark_age"])
      * `:faction` - Faction string (e.g., "mercenary", "clan_wolf")
      * `:type` - Unit type string (e.g., "battlemech", "combat_vehicle")

  ## Returns

    * `{:ok, units}` - List of matching units
    * `{:error, :term_too_short}` - When search term is less than 2 characters
    * `{:error, reason}` - When search fails for other reasons

  ## Examples

      iex> search("Atlas", %{eras: ["ilclan"], faction: "mercenary"})
      {:ok, [%MasterUnit{name: "Atlas", ...}, ...]}

      iex> search("A", %{})
      {:error, :term_too_short}
  """
  def search(search_term, filters \\ %{}) when is_binary(search_term) do
    search_term = String.trim(search_term)

    if String.length(search_term) < 2 do
      {:error, :term_too_short}
    else
      try do
        opts = build_search_opts_from_filters(filters)
        {:ok, do_search(search_term, opts)}
      rescue
        error ->
          Logger.error("Unit search failed for '#{search_term}': #{inspect(error)}")
          {:error, :search_failed}
      end
    end
  end

  defp do_search(search_term, opts) do
    local_results = search_local_units(search_term, opts)

    if length(local_results) > 0 do
      local_results
    else
      case search_and_cache_from_api(search_term, opts) do
        {:ok, units} ->
          units

        {:error, reason} ->
          Logger.info("MUL API search failed for '#{search_term}': #{reason}")
          []
      end
    end
  end

  @doc """
  Convert user-friendly filter format to the internal opts keyword list used
  by the local query pipeline. Public so LiveViews and tests can build opts
  consistently instead of duplicating the mapping.
  """
  def build_search_opts_from_filters(filters) when is_map(filters) do
    opts = []

    opts =
      case Map.get(filters, :type) do
        nil -> opts
        type -> [{:unit_type, type} | opts]
      end

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