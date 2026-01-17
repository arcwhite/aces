defmodule Aces.MUL.Client do
  @moduledoc """
  Client for Master Unit List API

  This module provides a respectful interface to the unofficial MUL API,
  with built-in rate limiting and error handling to be considerate of
  the external service.
  """

  require Logger

  @base_url "https://masterunitlist.azurewebsites.net"
  @rate_limit_delay 1000  # 1 second between requests
  @request_timeout 10_000  # 10 second timeout

  @doc """
  Fetches units from MUL API with filters

  ## Examples

      iex> Client.fetch_units(%{era: "ilclan", types: [18]})
      {:ok, [%{...}, ...]}
  """
  def fetch_units(filters \\ %{}) do
    with :ok <- rate_limit_check(),
         {:ok, response} <- make_request("/Unit/QuickList", filters) do
      units = parse_response(response, filters)
      {:ok, units}
    else
      {:error, :rate_limited} ->
        {:error, "Rate limited - please try again later"}

      {:error, %{status: status}} when status >= 400 ->
        {:error, "MUL API returned error status #{status}"}

      {:error, reason} ->
        Logger.warning("MUL API request failed: #{inspect(reason)}")
        {:error, "Failed to connect to MUL API"}
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
      {:ok, [unit | _]} -> {:ok, unit}
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Fetches a single unit by MUL ID and name.
  Uses name to search, then validates the ID matches.
  """
  def fetch_unit(mul_id, full_name) when is_integer(mul_id) and is_binary(full_name) do
    case fetch_units(%{name: full_name}) do
      {:ok, units} ->
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

  defp make_request(path, filters \\ %{}) do
    query_string = build_query_string(filters)
    url = "#{@base_url}#{path}#{query_string}"

    set_last_request_time()

    Logger.debug("Making MUL API request to: #{url}")

    case Req.get(url, receive_timeout: @request_timeout) do
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
      error -> error
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
      |> Enum.reject(&is_nil/1)
      |> Enum.join("&")

    if params == "", do: "", else: "?" <> params
  end

  defp encode_param(:era, "ilclan"), do: "AvailableEras=14"
  defp encode_param(:era, "dark_age"), do: "AvailableEras=13"
  defp encode_param(:era, "republic"), do: "AvailableEras=11"
  defp encode_param(:era, "clan_invasion"), do: "AvailableEras=4"

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
  defp encode_param(:name, name), do: "Name=#{URI.encode(name)}"

  defp encode_param(_, _), do: nil

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
    Enum.map(units, &normalize_unit(&1, faction_context))
  end

  defp parse_response(%{body: body}, _filters) when is_binary(body) do
    # Received HTML or other non-JSON response
    Logger.warning("MUL API returned non-JSON response for unit search")
    []
  end

  defp parse_response(_, _), do: []

  defp normalize_unit(api_data, faction_context \\ %{})

  defp normalize_unit(nil, _faction_context), do: nil

  defp normalize_unit(api_data, faction_context) do
    %{
      mul_id: api_data["Id"],
      name: api_data["Class"] || api_data["Name"],
      variant: api_data["Variant"],
      full_name: api_data["Name"],
      unit_type: map_unit_type(extract_type_name(api_data["Type"])),
      tonnage: api_data["Tonnage"],
      point_value: api_data["BFPointValue"],
      battle_value: api_data["BattleValue"],
      technology_base: extract_technology(api_data["Technology"]),
      rules_level: api_data["Rules"],
      role: extract_role(api_data["Role"]),
      cost: api_data["Cost"],
      date_introduced: api_data["DateIntroduced"],
      era_id: api_data["EraId"],
      bf_move: api_data["BFMove"],
      bf_size: api_data["BFSize"],
      bf_armor: api_data["BFArmor"],
      bf_structure: api_data["BFStructure"],
      bf_damage_short: to_string(api_data["BFDamageShort"] || ""),
      bf_damage_medium: to_string(api_data["BFDamageMedium"] || ""),
      bf_damage_long: to_string(api_data["BFDamageLong"] || ""),
      bf_overheat: api_data["BFOverheat"],
      bf_abilities: api_data["BFAbilities"],
      image_url: api_data["ImageUrl"],
      is_published: api_data["IsPublished"],
      factions: merge_faction_data(parse_factions(api_data["Factions"]), faction_context),
      last_synced_at: DateTime.utc_now()
    }
  end

  defp map_unit_type("BattleMech"), do: "battlemech"
  defp map_unit_type("Combat Vehicle"), do: "combat_vehicle"
  defp map_unit_type("Battle Armor"), do: "battle_armor"
  defp map_unit_type("Infantry"), do: "conventional_infantry"
  defp map_unit_type("ProtoMech"), do: "protomech"
  defp map_unit_type("Mech"), do: "battlemech"
  defp map_unit_type("BattleMechs"), do: "battlemech"
  defp map_unit_type("Mechs"), do: "battlemech"
  defp map_unit_type(_), do: "other"

  # Parse factions data - handle various possible formats from the API
  defp parse_factions(nil), do: %{}
  defp parse_factions([]), do: %{}
  
  defp parse_factions(factions) when is_list(factions) do
    # If it's a list of faction objects or strings, convert to map
    factions
    |> Enum.reduce(%{}, fn faction, acc ->
      case faction do
        %{"name" => name} -> Map.put(acc, String.downcase(name), true)
        %{"Name" => name} -> Map.put(acc, String.downcase(name), true)
        name when is_binary(name) -> Map.put(acc, String.downcase(name), true)
        _ -> acc
      end
    end)
  end
  
  defp parse_factions(factions) when is_map(factions) do
    # If it's already a map, ensure keys are lowercase
    factions
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, String.downcase(to_string(key)), value)
    end)
  end
  
  defp parse_factions(_), do: %{}

  # Build faction context from filters to store with units
  defp build_faction_context(filters) do
    case Map.get(filters, :factions) do
      factions when is_list(factions) ->
        # Convert faction names to a map indicating availability
        factions
        |> Enum.reduce(%{}, fn faction, acc ->
          Map.put(acc, String.downcase(faction), true)
        end)
      
      _ -> %{}
    end
  end

  # Merge API faction data with context from our request filters
  defp merge_faction_data(api_factions, filter_context) when is_map(api_factions) and is_map(filter_context) do
    Map.merge(api_factions, filter_context)
  end

  defp merge_faction_data(_api_factions, filter_context) when is_map(filter_context) do
    filter_context
  end

  defp merge_faction_data(api_factions, _) when is_map(api_factions) do
    api_factions
  end

  defp merge_faction_data(_, _), do: %{}

  # Extract technology name from API response
  defp extract_technology(%{"Name" => name}), do: name
  defp extract_technology(name) when is_binary(name), do: name
  defp extract_technology(_), do: nil

  # Extract role name from API response  
  defp extract_role(%{"Name" => name}), do: name
  defp extract_role(name) when is_binary(name), do: name
  defp extract_role(_), do: nil

  # Extract type name from API response
  defp extract_type_name(%{"Name" => name}), do: name
  defp extract_type_name(name) when is_binary(name), do: name
  defp extract_type_name(_), do: nil
end