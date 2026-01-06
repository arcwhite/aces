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
  Create or update a master unit from API data
  """
  def create_or_update_master_unit(attrs) when is_map(attrs) do
    case Repo.get_by(MasterUnit, mul_id: attrs[:mul_id] || attrs["mul_id"]) do
      nil ->
        %MasterUnit{}
        |> MasterUnit.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> MasterUnit.changeset(attrs)
        |> Repo.update()
    end
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
    |> order_by([u], fragment("similarity(?, ?) DESC", u.name, ^search_term))
    |> limit(50)
    |> Repo.all()
  end

  defp search_and_cache_from_api(search_term, opts) do
    filters = %{name: search_term}
              |> Map.merge(Enum.into(opts, %{}))

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

  defp fetch_and_cache_unit(mul_id) do
    case Client.fetch_unit(mul_id) do
      {:ok, unit_data} ->
        create_or_update_master_unit(unit_data)

      error -> error
    end
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
    case Client.fetch_unit(unit.mul_id) do
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

  defp apply_filters(query, [{:era, era} | rest]) when era in ["ilclan", "dark_age", "republic", "clan_invasion"] do
    era_id = case era do
      "ilclan" -> 14
      "dark_age" -> 13
      "republic" -> 11
      "clan_invasion" -> 4
    end

    query
    |> where([u], u.era_id == ^era_id)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:faction, faction} | rest]) when is_binary(faction) do
    # Use PostgreSQL JSON query to check if faction exists in the factions map
    query
    |> where([u], fragment("? \\? ?", u.factions, ^String.downcase(faction)))
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:factions, factions} | rest]) when is_list(factions) do
    # Check if unit is available to any of the specified factions
    lowercase_factions = Enum.map(factions, &String.downcase/1)
    
    query
    |> where([u], fragment("? \\?| ?", u.factions, ^lowercase_factions))
    |> apply_filters(rest)
  end

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)
end