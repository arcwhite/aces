defmodule Aces.MUL.Client do
  @moduledoc """
  Client for Master Unit List API

  This module provides a respectful interface to the unofficial MUL API,
  with built-in rate limiting and error handling to be considerate of
  the external service.

  ## Return contract

  `fetch_units/1` returns typed results so callers can distinguish failure
  modes and stop collapsing "rate limited", "DNS failed", "bad query", and
  "zero results" into an empty list:

    * `{:ok, {units, source}}` — `source` is `:api` for live fetches, or
      `:fixture` when the fixture-backed client is configured (see below).
    * `{:error, {:mul_unavailable, reason}}` — the MUL service was
      unreachable or refused us: transport failure, timeout, 429, 5xx.
      The caller should treat data as unknown, not empty.
    * `{:error, {:query_failed, reason}}` — the MUL rejected or malformed
      our request: 4xx client errors, non-JSON responses, or a filter key
      outside `@supported_filter_keys`
      (`{:unsupported_filter, key}`). This is a bug in our filter shape,
      not a service outage.

  ## Fixture-backed access

  When `config :aces, :mul_client_source, :fixture` is set (see
  `bin/local-smoke` and the test env), calls are dispatched to
  `Aces.MUL.FixtureClient` instead of hitting the live service. This keeps
  smoke and unit tests off the external API.
  """

  alias Aces.MUL.TypeMapping

  require Logger

  @base_url "https://masterunitlist.azurewebsites.net"
  @rate_limit_delay 1000  # 1 second between requests
  @request_timeout 10_000  # 10 second timeout

  # Filter keys the QuickList endpoint understands. Anything outside this
  # set is a bug in the caller — see fetch_units/1's allowlist check.
  @supported_filter_keys ~w(era eras types factions min_tons max_tons name)a

  @doc """
  Fetches units, dispatching to the fixture client when so configured.

  ## Examples

      iex> Client.fetch_units(%{era: "ilclan", types: [18]})
      {:ok, {[%{...}, ...], :api}}
  """
  def fetch_units(filters \\ %{}) do
    # Filter-shape validation is a caller-bug check, so it runs ahead of the
    # source dispatch — fixture-backed callers (tests, bin/local-smoke) must
    # get the same {:unsupported_filter, key} contract as live API callers.
    with :ok <- validate_filter_keys(filters) do
      case source() do
        :fixture -> Aces.MUL.FixtureClient.fetch_units(filters)
        _ -> fetch_units_from_api(filters)
      end
    end
  end

  defp source do
    Application.get_env(:aces, :mul_client_source, :api)
  end

  defp fetch_units_from_api(filters) do
    with :ok <- rate_limit_check(),
         {:ok, response} <- make_request("/Unit/QuickList", filters),
         {:ok, units} <- parse_response(response, filters) do
      {:ok, {units, :api}}
    else
      {:error, :rate_limited} ->
        {:error, {:mul_unavailable, :rate_limited}}

      {:error, {:non_json_response, _} = reason} ->
        Logger.warning("MUL API returned non-JSON body")
        {:error, {:query_failed, reason}}

      {:error, %{status: status, body: body}} when status >= 500 ->
        Logger.warning("MUL API server error #{status}: #{inspect(body)}")
        {:error, {:mul_unavailable, {:server_error, status}}}

      {:error, %{status: status, body: body}} when status >= 400 ->
        Logger.warning("MUL API client error #{status}: #{inspect(body)}")
        {:error, {:query_failed, {:client_error, status}}}

      {:error, reason} ->
        Logger.warning("MUL API request failed: #{inspect(reason)}")
        {:error, {:mul_unavailable, {:transport_error, reason}}}
    end
  end

  # An unsupported filter key is a malformed request on our side, so it maps
  # onto the :query_failed half of the typed contract rather than escaping as
  # its own untyped shape — see the "Return contract" section above.
  defp validate_filter_keys(filters) when is_map(filters) do
    case Enum.find(Map.keys(filters), fn key -> key not in @supported_filter_keys end) do
      nil -> :ok
      bad_key -> {:error, {:query_failed, {:unsupported_filter, bad_key}}}
    end
  end

  @doc """
  Fetches a single unit by MUL ID using the QuickList API.
  Requires the unit's full_name to search for it.
  """
  def fetch_unit(mul_id) when is_integer(mul_id) do
    # The Details endpoint returns HTML, not JSON
    # We need the unit's name to search via QuickList
    Logger.warning("fetch_unit/1 requires a unit name to search - use fetch_unit_by_name/1 instead")
    {:error, :not_supported}
  end

  @doc """
  Fetches a single unit by its full name using the QuickList API.
  Returns the unit data if found, or an error.
  """
  def fetch_unit_by_name(full_name) when is_binary(full_name) do
    case fetch_units(%{name: full_name}) do
      {:ok, {[unit | _], _source}} -> {:ok, unit}
      {:ok, {[], _source}} -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Fetches a single unit by MUL ID and name.
  Uses name to search, then validates the ID matches.
  """
  def fetch_unit(mul_id, full_name) when is_integer(mul_id) and is_binary(full_name) do
    case fetch_units(%{name: full_name}) do
      {:ok, {units, _source}} ->
        case Enum.find(units, fn u -> u.mul_id == mul_id end) do
          nil -> {:error, :not_found}
          unit -> {:ok, unit}
        end

      error ->
        error
    end
  end

  @doc """
  Returns URL for unit image from MUL
  """
  def fetch_unit_image_url(mul_id) when is_integer(mul_id) do
    "#{@base_url}/Unit/QuickImage/#{mul_id}"
  end

  # Private functions

  defp rate_limit_check do
    case get_last_request_time() do
      nil ->
        :ok

      last_time ->
        elapsed = System.monotonic_time(:millisecond) - last_time

        if elapsed < @rate_limit_delay do
          sleep_time = @rate_limit_delay - elapsed
          Process.sleep(sleep_time)
        end

        :ok
    end
  end

  defp make_request(path, filters) do
    query_string = build_query_string(filters)
    url = "#{@base_url}#{path}#{query_string}"

    set_last_request_time()

    Logger.info("MUL API request: #{url}")
    Logger.info("MUL API filters: #{inspect(filters)}")

    case Req.get(url, receive_timeout: @request_timeout) do
      {:ok, %{status: 429}} ->
        Logger.warning("MUL API rate limited us (429)")
        {:error, :rate_limited}

      {:ok, %{status: status} = response} when status >= 400 ->
        {:error, %{status: status, body: response.body}}

      {:ok, response} ->
        # Ensure consistent body parsing - decode JSON if it's a string
        body = case response.body do
          body when is_binary(body) ->
            case Jason.decode(body) do
              {:ok, json} -> json
              {:error, _} -> body  # Keep as string if not valid JSON
            end
          body -> body  # Already parsed or other format
        end
        {:ok, %{response | body: body}}

      error ->
        error
    end
  end

  defp get_last_request_time do
    :persistent_term.get({__MODULE__, :last_request}, nil)
  end

  defp set_last_request_time do
    :persistent_term.put({__MODULE__, :last_request}, System.monotonic_time(:millisecond))
  end

  defp build_query_string(filters) when filters == %{}, do: ""

  defp build_query_string(filters) do
    params =
      filters
      |> Enum.map(fn {key, value} -> encode_param(key, value) end)
      |> Enum.reject(fn p -> is_nil(p) or p == "" end)
      |> Enum.join("&")

    if params == "", do: "", else: "?" <> params
  end

  # Era IDs from https://masterunitlist.azurewebsites.net/Era/Index
  # IMPORTANT: These must match the actual MUL era IDs
  @era_ids %{
    "ilclan" => 257,
    "dark_age" => 16,
    "late_republic" => 254,
    "republic" => 254,  # Alias for late_republic
    "early_republic" => 15,
    "jihad" => 14,
    "civil_war" => 247,
    "clan_invasion" => 13,
    "late_succession_war" => 256,
    "early_succession_war" => 11,
    "star_league" => 10
  }

  # Single era
  defp encode_param(:era, era) when is_binary(era) do
    case Map.get(@era_ids, era) do
      nil -> nil
      id -> "AvailableEras=#{id}"
    end
  end

  # Multiple eras (list)
  defp encode_param(:eras, eras) when is_list(eras) do
    eras
    |> Enum.map(&Map.get(@era_ids, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("&", fn id -> "AvailableEras=#{id}" end)
  end

  defp encode_param(:types, types) when is_list(types) do
    Enum.map_join(types, "&", fn t -> "Types=#{t}" end)
  end

  defp encode_param(:factions, factions) when is_list(factions) do
    factions
    |> Enum.map(&faction_name_to_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("&", fn id -> "Factions=#{id}" end)
  end

  defp encode_param(:min_tons, tons), do: "MinTons=#{tons}"
  defp encode_param(:max_tons, tons), do: "MaxTons=#{tons}"
  defp encode_param(:min_pv, pv), do: "MinPV=#{pv}"
  defp encode_param(:max_pv, pv), do: "MaxPV=#{pv}"
  defp encode_param(:name, name), do: "Name=#{URI.encode(name)}"

  # Faction name to ID mapping (extracted from https://masterunitlist.azurewebsites.net/Faction/Index)
  @faction_mappings %{
    # Key factions for mercenary play
    "mercenary" => 34,
    "mercenaries" => 34,  # Alias
    
    # Inner Sphere Great Powers
    "capellan_confederation" => 5,
    "draconis_combine" => 27,
    "federated_suns" => 29,
    "free_worlds_league" => 30,
    "lyran_commonwealth" => 60,
    "lyran_alliance" => 32,
    "federated_commonwealth" => 84,
    
    # Republic Era
    "republic_of_the_sphere" => 41,
    
    # Major Clans
    "clan_wolf" => 24,
    "clan_jade_falcon" => 15,
    "clan_ghost_bear" => 11,
    "clan_smoke_jaguar" => 20,
    "clan_diamond_shark" => 8,
    "clan_sea_fox" => 82,  # Successor to Diamond Shark
    "clan_nova_cat" => 17,
    "clan_snow_raven" => 21,
    "clan_hell_horses" => 13,
    "clan_ice_hellion" => 14,
    "clan_goliath_scorpion" => 12,
    "clan_fire_mandrill" => 10,
    "clan_star_adder" => 19,
    "clan_cloud_cobra" => 6,
    "clan_coyote" => 7,
    
    # Other factions
    "comstar" => 18,
    "word_of_blake" => 23,
    "free_rasalhague_republic" => 28,
    "st_ives_compact" => 83,
    "circinus_federation" => 9,
    "mercenary_review_and_bonding_commission" => 35
  }

  defp faction_name_to_id(faction_name) when is_binary(faction_name) do
    Map.get(@faction_mappings, String.downcase(faction_name))
  end

  defp faction_name_to_id(faction_id) when is_integer(faction_id), do: faction_id

  @doc """
  Returns available faction names for filtering
  """
  def available_factions do
    Map.keys(@faction_mappings)
  end

  @doc """
  Returns the faction mapping for reference
  """
  def faction_mappings, do: @faction_mappings

  defp parse_response(%{body: %{"Units" => units}}, filters) when is_list(units) do
    # Extract faction names from filters to store with units
    faction_context = build_faction_context(filters)
    {:ok, Enum.map(units, &normalize_unit(&1, faction_context))}
  end

  defp parse_response(%{body: body}, _filters) when is_binary(body) do
    # Received HTML or other non-JSON response
    Logger.warning("MUL API returned non-JSON response for unit search")
    {:error, {:non_json_response, :body_is_string}}
  end

  defp parse_response(%{body: body}, _filters) do
    {:error, {:non_json_response, {:unexpected_body_shape, body}}}
  end

  @doc """
  Normalizes a single raw MUL API unit map into our internal unit map.

  Exposed primarily so unit-type resolution (notably the battle armor vs
  conventional infantry split by `BFType`) can be tested without hitting the
  network. Faction context is empty here; the full pipeline supplies it.
  """
  def normalize_unit(api_data), do: normalize_unit(api_data, %{})

  defp normalize_unit(api_data, faction_context)

  defp normalize_unit(nil, _faction_context), do: nil

  defp normalize_unit(api_data, faction_context) do
    %{
      mul_id: safe_integer(api_data["Id"]),
      name: api_data["Class"] || api_data["Name"],
      variant: api_data["Variant"],
      full_name: api_data["Name"],
      unit_type: TypeMapping.resolve(api_data["Type"], api_data["BFType"]),
      bf_type: api_data["BFType"],
      tonnage: safe_integer(api_data["Tonnage"]),
      point_value: safe_integer(api_data["BFPointValue"]),
      battle_value: safe_integer(api_data["BattleValue"]),
      technology_base: extract_technology(api_data["Technology"]),
      rules_level: api_data["Rules"],
      role: extract_role(api_data["Role"]),
      cost: safe_integer(api_data["Cost"]),
      date_introduced: safe_integer(api_data["DateIntroduced"]),
      era_id: safe_integer(api_data["EraId"]),
      bf_move: api_data["BFMove"],
      bf_size: safe_integer(api_data["BFSize"]),
      bf_armor: safe_integer(api_data["BFArmor"]),
      bf_structure: safe_integer(api_data["BFStructure"]),
      bf_damage_short: to_string(api_data["BFDamageShort"] || ""),
      bf_damage_medium: to_string(api_data["BFDamageMedium"] || ""),
      bf_damage_long: to_string(api_data["BFDamageLong"] || ""),
      bf_overheat: safe_integer(api_data["BFOverheat"]),
      bf_abilities: api_data["BFAbilities"],
      image_url: api_data["ImageUrl"],
      is_published: api_data["IsPublished"],
      factions: build_era_keyed_factions(api_data["Factions"], faction_context),
      last_synced_at: DateTime.utc_now()
    }
  end

  # Build era-aware faction context from filters. The API's Factions field is
  # a flat list of faction names — we know which era they apply to only
  # because *we* asked the API for a particular era, so era context comes
  # from the request filters, not the response.
  #
  # Returns %{"era" => [faction_from_filter, ...]} — one entry per requested
  # era. Filter factions may be empty (only eras were set); the era key still
  # exists so API-returned factions can be folded into it downstream.
  defp build_faction_context(filters) do
    eras =
      case {Map.get(filters, :era), Map.get(filters, :eras)} do
        {nil, eras} when is_list(eras) -> eras
        {era, _} when is_binary(era) -> [era]
        _ -> []
      end

    filter_factions =
      filters
      |> Map.get(:factions, [])
      |> Enum.map(&String.downcase/1)

    Enum.reduce(eras, %{}, fn era, acc ->
      Map.put(acc, era, filter_factions)
    end)
  end

  # Always produce an era-keyed factions map. The API's `Factions` value is a
  # bare list of faction names with no era attached; the only era information
  # we have is what *we* asked for (era_context). So:
  #
  #   * era_context present  → fold API-returned factions into each requested
  #                            era, unioned with any faction filter values.
  #   * era_context empty and API returned factions → drop them and log. A
  #                            faction with no era cannot be represented in
  #                            our schema, and smuggling it in as a top-level
  #                            key mixes era keys with faction keys and
  #                            corrupts every downstream reader.
  #   * both empty → %{}
  defp build_era_keyed_factions(api_factions, era_context) do
    api_list = extract_api_faction_list(api_factions)

    cond do
      map_size(era_context) > 0 ->
        Enum.reduce(era_context, %{}, fn {era, filter_factions}, acc ->
          Map.put(acc, era, Enum.uniq(filter_factions ++ api_list))
        end)

      api_list == [] ->
        %{}

      true ->
        Logger.debug(
          "MUL API returned #{length(api_list)} factions with no era context — dropping"
        )

        %{}
    end
  end

  # Normalize the API's Factions field into a flat, lowercased list of names.
  # Handles the various shapes MUL has returned (list of strings, list of
  # objects with either "name" or "Name"). Maps and unexpected values yield
  # an empty list.
  defp extract_api_faction_list(nil), do: []
  defp extract_api_faction_list([]), do: []

  defp extract_api_faction_list(factions) when is_list(factions) do
    factions
    |> Enum.reduce([], fn faction, acc ->
      case faction do
        %{"name" => name} when is_binary(name) -> [String.downcase(name) | acc]
        %{"Name" => name} when is_binary(name) -> [String.downcase(name) | acc]
        name when is_binary(name) -> [String.downcase(name) | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp extract_api_faction_list(_), do: []

  # Extract technology name from API response
  defp extract_technology(%{"Name" => name}), do: name
  defp extract_technology(name) when is_binary(name), do: name
  defp extract_technology(_), do: nil

  # Extract role name from API response  
  defp extract_role(%{"Name" => name}), do: name
  defp extract_role(name) when is_binary(name), do: name
  defp extract_role(_), do: nil


  # Safely parse integer values from API responses
  # Handles nil, integers, floats, and string representations
  defp safe_integer(nil), do: nil
  defp safe_integer(val) when is_integer(val), do: val
  defp safe_integer(val) when is_float(val), do: trunc(val)
  defp safe_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end
  defp safe_integer(_), do: nil
end