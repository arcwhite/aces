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
  alias Aces.MUL.TypeMapping

  require Logger

  @cache_ttl_days 30  # Refresh cached units after 30 days

  @doc """
  Search for units — checks local DB first, falls back to the MUL client.

  This function returns a plain list for backward compatibility with the
  draft LiveView. Prefer `search/2` for new callers — it identifies where
  the units came from (`:local`, `:api`, `:fixture`) and surfaces specific
  failure modes in the return value instead of collapsing them to `[]`.
  """
  @deprecated "Use search/2 for typed results including error branches"
  def search_units(search_term, opts \\ []) when is_binary(search_term) do
    case search(search_term, opts) do
      {:ok, %{units: units}} ->
        units

      {:error, :term_too_short} ->
        []

      {:error, reason} ->
        Logger.info("MUL API search failed for '#{search_term}': #{inspect(reason)}")
        []
    end
  end

  @doc """
  Typed unit search. Returns a tagged tuple naming what happened so callers
  can distinguish cache hits from MUL fallbacks and from targeted failures
  like rate limiting or filter validation errors.

  Result shapes:

    * `{:ok, %{units: [_ | _], source: :local}}` — served entirely from the
      local cache.
    * `{:ok, %{units: units, source: :api | :fixture}}` — cache miss, so we
      fell through to `Aces.MUL.Client`; `source` names which backing the
      client used (see its `mul_client_source` config).
    * `{:error, :term_too_short}` — trimmed term shorter than two chars.
    * `{:error, {:mul_unavailable, reason}}` — network failure, rate
      limiting, or HTTP error from MUL. `reason` is the underlying value
      from the client.
    * `{:error, {:query_failed, reason}}` — Postgres blew up on the local
      lookup, or MUL rejected the query. `reason` is the underlying value.

  There is no distinct "MUL had nothing" tag: that state is an empty
  `:units` list with a non-`:local` `source`, which callers can match
  directly (`%{units: [], source: s} when s != :local`).
  """
  @spec search(String.t(), keyword()) ::
          {:ok, %{units: [MasterUnit.t()], source: :local | :api | :fixture}}
          | {:error,
             :term_too_short
             | {:mul_unavailable, term()}
             | {:query_failed, term()}}
  def search(search_term, opts \\ []) when is_binary(search_term) do
    search_term = String.trim(search_term)

    if String.length(search_term) < 2 do
      {:error, :term_too_short}
    else
      # The rescue is deliberately scoped to search_local_units/2 only: a
      # raise from search_and_cache_from_api/2 (e.g. inside
      # create_or_update_master_unit/1) must not be misattributed to the
      # local DB path — the whole point of the typed error contract is to
      # name the actual failing subsystem.
      case safe_search_local(search_term, opts) do
        {:ok, []} ->
          search_and_cache_from_api(search_term, opts)

        {:ok, local_results} ->
          {:ok, %{units: local_results, source: :local}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp safe_search_local(search_term, opts) do
    {:ok, search_local_units(search_term, opts)}
  rescue
    error ->
      Logger.error("Local unit search failed for '#{search_term}': #{inspect(error)}")
      {:error, {:query_failed, {:local_search_raised, error.__struct__}}}
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
  Get master units from local cache, ordered by point_value then name.

  Options:
    * `:limit` — max rows to return (default `50`).
    * Everything else is forwarded to `Aces.Units.Filters.filter/2`.

  This is the local-only path used by the search modal's default view; it
  never falls back to MUL.
  """
  def list_cached_master_units(opts \\ []) do
    {limit, filter_opts} = Keyword.pop(opts, :limit, 50)

    MasterUnit
    |> Filters.filter(filter_opts)
    |> order_by([u], [u.point_value, u.name])
    |> limit(^limit)
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
    api_filters =
      opts
      |> translate_filters_for_api()
      |> Map.put(:name, search_term)

    case Client.fetch_units(api_filters) do
      {:ok, {api_units, source}} ->
        cached_units =
          api_units
          |> Enum.map(&create_or_update_master_unit/1)
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, unit} -> unit end)
          |> post_filter_by_unit_type(opts)

        # An empty list here is a legitimate zero-match result, not an error;
        # callers read it off {units: [], source: source}.
        {:ok, %{units: cached_units, source: source}}

      # The client already returns {:mul_unavailable, _} / {:query_failed, _},
      # so re-wrapping here would nest the tag twice.
      {:error, _typed} = error ->
        error
    end
  end

  # Translate internal filter format to MUL API format.
  #
  # `:unit_type` is expanded to the MUL Types ids `TypeMapping` associates
  # with it. Because a MUL type id can cover more internal unit types than
  # we asked for (e.g. Types=21 returns both battle armor and conventional
  # infantry, Types=18 returns both battlemechs and industrial mechs), the
  # returned units are also post-filtered locally on the resolved unit_type
  # — see `post_filter_by_unit_type/2`.
  defp translate_filters_for_api(opts) do
    Enum.reduce(opts, %{}, fn
      {:era_faction, {eras, faction}}, acc ->
        acc
        |> Map.put(:eras, eras)
        |> Map.put(:factions, [faction])

      {:eras, eras}, acc when is_list(eras) ->
        Map.put(acc, :eras, eras)

      {:faction, faction}, acc when is_binary(faction) ->
        Map.put(acc, :factions, [faction])

      {:unit_type, type}, acc ->
        case TypeMapping.to_mul_ids(type) do
          [] -> acc
          ids -> Map.put(acc, :types, ids)
        end

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  # Post-filter API-cached rows on the resolved unit_type so a request for
  # e.g. "conventional_infantry" doesn't leak battle_armor rows from the
  # same Types=21 fetch. We still cache everything MUL returned — the
  # filter only trims the returned subset.
  defp post_filter_by_unit_type(units, opts) do
    case Keyword.get(opts, :unit_type) do
      nil -> units
      type -> Enum.filter(units, fn unit -> unit.unit_type == type end)
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

  Thin wrapper over `search/2` that translates the modal's `{:type, :eras,
  :faction}` filter map into the internal `opts` shape. Every return value
  comes straight from `search/2` — no `try/rescue → :search_failed`
  swallowing.

  ## Parameters

    * `search_term` - The text to search for (minimum 2 characters)
    * `filters` - Map with user-friendly keys:
      * `:eras` - List of era strings (e.g., ["ilclan", "dark_age"])
      * `:faction` - Faction string (e.g., "mercenary", "clan_wolf")
      * `:type` - Unit type string (e.g., "battlemech", "combat_vehicle")

  ## Returns

  Exactly what `search/2` returns:

    * `{:ok, %{units: units, source: source}}` — `source` is `:local`,
      `:api`, or `:fixture`, identifying where the units came from so
      callers can surface it. An empty `:units` with a non-`:local` source
      means MUL was reached and had no matches.
    * `{:error, :term_too_short}` — search term below 2 characters.
    * `{:error, {:mul_unavailable, reason}}` — MUL unreachable / rate-limited.
    * `{:error, {:query_failed, reason}}` — MUL rejected the query or a local
      DB failure was caught.

  ## Examples

      iex> search_units_for_company("Atlas", %{eras: ["ilclan"], faction: "mercenary"})
      {:ok, %{units: [%MasterUnit{name: "Atlas", ...}, ...], source: :local}}

      iex> search_units_for_company("A", %{})
      {:error, :term_too_short}
  """
  def search_units_for_company(search_term, filters \\ %{}) when is_binary(search_term) do
    filters
    |> build_search_opts_from_filters()
    |> then(&search(search_term, &1))
  end

  @doc """
  Convert the modal's user-friendly filter map to the internal opts keyword
  list that `search/2` and `list_cached_master_units/1` accept.

  Era and faction are independent selections in the UI, so deselecting one
  must not silently disable the other. Three cases matter:

    * both eras and a faction → `{:era_faction, {eras, faction}}`
      (faction available in one of the named eras)
    * only a faction          → `{:faction, faction}`
      (available to that faction in any era)
    * only eras               → `{:eras, eras}`
      (available in any of those eras, faction unrestricted)

  Neither set → no era/faction opt at all.
  """
  def build_search_opts_from_filters(filters) when is_map(filters) do
    opts = []

    opts =
      case Map.get(filters, :type) do
        nil -> opts
        type -> [{:unit_type, type} | opts]
      end

    eras = Map.get(filters, :eras)
    faction = Map.get(filters, :faction)
    has_eras? = is_list(eras) and length(eras) > 0
    has_faction? = is_binary(faction) and faction != ""

    cond do
      has_eras? and has_faction? ->
        [{:era_faction, {eras, faction}} | opts]

      has_faction? ->
        [{:faction, faction} | opts]

      has_eras? ->
        [{:eras, eras} | opts]

      true ->
        opts
    end
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