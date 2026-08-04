defmodule Aces.MUL.FixtureClient do
  @moduledoc """
  Fixture-backed stand-in for `Aces.MUL.Client` used by smoke tests, unit
  tests, and any other environment that must not hit the live MUL service.

  Returns the same typed result contract as the live client
  (`{:ok, {units, source}}` / `{:error, {kind, reason}}`) so callers cannot
  observe whether they are talking to fixtures or to the network. The
  `source` field is always `:fixture`, letting callers surface that fact to
  operators without changing their error-handling code.

  Fixtures live in `priv/mul_fixtures/units.json` so they can be edited or
  regenerated without recompiling.
  """

  require Logger

  @doc """
  Filters the in-memory fixture set against the same filter shape the live
  client accepts. Empty matches return `{:ok, {[], :fixture}}` — an empty
  set is a legitimate zero-match result, not an error.
  """
  def fetch_units(filters \\ %{}) do
    case load_fixtures() do
      {:ok, fixtures} ->
        {:ok, {filter_units(fixtures, filters), :fixture}}

      {:error, reason} ->
        Logger.error("MUL fixture load failed: #{inspect(reason)}")
        {:error, {:query_failed, {:fixture_load_failed, reason}}}
    end
  end

  defp fixture_path do
    Application.get_env(:aces, :mul_fixture_path) ||
      Path.join(Application.app_dir(:aces, "priv"), "mul_fixtures/units.json")
  end

  defp load_fixtures do
    case File.read(fixture_path()) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"units" => units}} when is_list(units) ->
            {:ok, Enum.map(units, &normalize_fixture/1)}

          {:ok, other} ->
            {:error, {:malformed_fixtures, other}}

          {:error, reason} ->
            {:error, {:json_decode_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp normalize_fixture(unit) do
    %{
      mul_id: unit["mul_id"],
      name: unit["name"],
      variant: unit["variant"],
      full_name: unit["full_name"] || "#{unit["name"]} #{unit["variant"]}" |> String.trim(),
      unit_type: unit["unit_type"],
      bf_type: unit["bf_type"],
      tonnage: unit["tonnage"],
      point_value: unit["point_value"],
      battle_value: unit["battle_value"],
      technology_base: unit["technology_base"],
      rules_level: unit["rules_level"],
      role: unit["role"],
      cost: unit["cost"],
      date_introduced: unit["date_introduced"],
      era_id: unit["era_id"],
      bf_move: unit["bf_move"],
      bf_size: unit["bf_size"],
      bf_armor: unit["bf_armor"],
      bf_structure: unit["bf_structure"],
      bf_damage_short: unit["bf_damage_short"] || "",
      bf_damage_medium: unit["bf_damage_medium"] || "",
      bf_damage_long: unit["bf_damage_long"] || "",
      bf_overheat: unit["bf_overheat"],
      bf_abilities: unit["bf_abilities"],
      image_url: unit["image_url"],
      is_published: Map.get(unit, "is_published", true),
      factions: unit["factions"] || %{},
      last_synced_at: DateTime.utc_now()
    }
  end

  defp filter_units(units, filters) do
    eras = normalize_eras(Map.get(filters, :era) || Map.get(filters, :eras))
    factions = normalize_factions(Map.get(filters, :factions))

    units
    |> filter_by_name(Map.get(filters, :name))
    |> filter_by_types(Map.get(filters, :types))
    |> filter_by_unit_type(Map.get(filters, :unit_type))
    |> filter_by_era_faction(eras, factions)
    |> filter_by_tonnage(Map.get(filters, :min_tons), Map.get(filters, :max_tons))
  end

  defp filter_by_name(units, nil), do: units
  defp filter_by_name(units, ""), do: units

  defp filter_by_name(units, name) when is_binary(name) do
    needle = String.downcase(name)

    Enum.filter(units, fn unit ->
      haystack = String.downcase(unit.full_name || unit.name || "")
      String.contains?(haystack, needle)
    end)
  end

  defp filter_by_types(units, nil), do: units
  defp filter_by_types(units, []), do: units

  defp filter_by_types(units, type_ids) when is_list(type_ids) do
    allowed = Enum.flat_map(type_ids, &type_id_to_unit_types/1)
    if allowed == [], do: units, else: Enum.filter(units, &(&1.unit_type in allowed))
  end

  # MUL Type 21 ("Infantry" supertype) covers both battle_armor and
  # conventional_infantry, so it expands to both concrete unit_types.
  defp type_id_to_unit_types(18), do: ["battlemech"]
  defp type_id_to_unit_types(19), do: ["combat_vehicle"]
  defp type_id_to_unit_types(20), do: ["protomech"]
  defp type_id_to_unit_types(21), do: ["battle_armor", "conventional_infantry"]
  defp type_id_to_unit_types(_), do: []

  defp filter_by_unit_type(units, nil), do: units
  defp filter_by_unit_type(units, ""), do: units

  defp filter_by_unit_type(units, "infantry"),
    do: Enum.filter(units, &(&1.unit_type in ["battle_armor", "conventional_infantry"]))

  defp filter_by_unit_type(units, unit_type) when is_binary(unit_type) do
    Enum.filter(units, &(&1.unit_type == unit_type))
  end

  defp normalize_eras(nil), do: nil
  defp normalize_eras(""), do: nil
  defp normalize_eras([]), do: nil
  defp normalize_eras(era) when is_binary(era), do: [era]
  defp normalize_eras(eras) when is_list(eras), do: eras

  defp normalize_factions(nil), do: nil
  defp normalize_factions([]), do: nil

  defp normalize_factions(factions) when is_list(factions),
    do: Enum.map(factions, &String.downcase/1)

  # When both eras and factions are present, we intersect them: keep a unit
  # only if it lists one of the wanted factions *within* one of the wanted
  # eras. Filtering them independently would let, e.g.,
  # {eras: ["ilclan"], factions: ["draconis_combine"]} match a unit that
  # lists draconis_combine only under "clan_invasion" — surfacing units the
  # live MUL would exclude for the same query.
  defp filter_by_era_faction(units, nil, nil), do: units

  defp filter_by_era_faction(units, eras, nil) do
    Enum.filter(units, fn unit ->
      factions_map = unit.factions || %{}
      Enum.any?(eras, &Map.has_key?(factions_map, &1))
    end)
  end

  defp filter_by_era_faction(units, nil, wanted_factions) do
    Enum.filter(units, fn unit ->
      unit_factions = unit.factions || %{}

      Enum.any?(unit_factions, fn {_era, faction_list} ->
        Enum.any?(wanted_factions, &(&1 in (faction_list || [])))
      end)
    end)
  end

  defp filter_by_era_faction(units, eras, wanted_factions) do
    Enum.filter(units, fn unit ->
      unit_factions = unit.factions || %{}

      Enum.any?(eras, fn era ->
        era_list = Map.get(unit_factions, era) || []
        Enum.any?(wanted_factions, &(&1 in era_list))
      end)
    end)
  end

  defp filter_by_tonnage(units, nil, nil), do: units

  defp filter_by_tonnage(units, min_tons, max_tons) do
    Enum.filter(units, fn unit ->
      tonnage = unit.tonnage
      is_integer(tonnage) and
        (is_nil(min_tons) or tonnage >= min_tons) and
        (is_nil(max_tons) or tonnage <= max_tons)
    end)
  end
end
