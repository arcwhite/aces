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
      units = parse_response(response)
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
  Fetches a single unit by MUL ID
  """
  def fetch_unit(mul_id) when is_integer(mul_id) do
    with :ok <- rate_limit_check(),
         {:ok, response} <- make_request("/Unit/Details/#{mul_id}") do
      case response.status do
        200 ->
          {:ok, parse_unit_details(response.body)}

        404 ->
          {:error, :not_found}

        _ ->
          {:error, "MUL API returned status #{response.status}"}
      end
    else
      {:error, reason} ->
        Logger.warning("MUL API unit fetch failed: #{inspect(reason)}")
        {:error, reason}
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

    Req.get(url, receive_timeout: @request_timeout)
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

  defp encode_param(:min_tons, tons), do: "MinTons=#{tons}"
  defp encode_param(:max_tons, tons), do: "MaxTons=#{tons}"
  defp encode_param(:name, name), do: "Name=#{URI.encode(name)}"

  defp encode_param(_, _), do: nil

  defp parse_response(%{body: %{"Units" => units}}) when is_list(units) do
    Enum.map(units, &normalize_unit/1)
  end

  defp parse_response(_), do: []

  defp normalize_unit(api_data) do
    %{
      mul_id: api_data["Id"],
      name: api_data["Name"],
      variant: api_data["Variant"],
      full_name: build_full_name(api_data["Name"], api_data["Variant"]),
      unit_type: map_unit_type(api_data["Type"]),
      tonnage: api_data["Tonnage"],
      point_value: api_data["BFPointValue"],
      battle_value: api_data["BattleValue"],
      technology_base: api_data["Technology"],
      rules_level: api_data["Rules"],
      role: api_data["Role"],
      cost: api_data["Cost"],
      date_introduced: api_data["DateIntroduced"],
      era_id: api_data["EraId"],
      bf_move: api_data["BFMove"],
      bf_armor: api_data["BFArmor"],
      bf_structure: api_data["BFStructure"],
      bf_damage_short: api_data["BFDamageShort"],
      bf_damage_medium: api_data["BFDamageMedium"],
      bf_damage_long: api_data["BFDamageLong"],
      bf_overheat: api_data["BFOverheat"],
      bf_abilities: api_data["BFAbilities"],
      image_url: api_data["ImageUrl"],
      is_published: api_data["IsPublished"],
      last_synced_at: DateTime.utc_now()
    }
  end

  defp parse_unit_details(body) do
    # For now, assume the details API has similar structure
    # This would need to be updated based on actual API response
    normalize_unit(body)
  end

  defp build_full_name(name, nil), do: name
  defp build_full_name(name, ""), do: name
  defp build_full_name(name, variant), do: "#{name} #{variant}"

  defp map_unit_type("BattleMech"), do: "battlemech"
  defp map_unit_type("Combat Vehicle"), do: "combat_vehicle"
  defp map_unit_type("Battle Armor"), do: "battle_armor"
  defp map_unit_type("Infantry"), do: "conventional_infantry"
  defp map_unit_type("ProtoMech"), do: "protomech"
  defp map_unit_type(_), do: "other"
end