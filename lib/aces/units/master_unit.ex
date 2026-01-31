defmodule Aces.Units.MasterUnit do
  @moduledoc """
  Schema for master unit list entries from masterunitlist.info

  ## Factions Field Format

  The `factions` field stores era-aware faction availability as a map:

      %{
        "ilclan" => ["mercenary", "capellan_confederation"],
        "dark_age" => ["mercenary", "free_worlds_league"]
      }

  This format allows tracking which factions have access to a unit in each era,
  since faction availability can change between eras (e.g., a unit might become
  more widely available in later eras as technology spreads).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.CompanyUnit

  @valid_unit_types ~w(battlemech combat_vehicle battle_armor conventional_infantry protomech other)
  @valid_eras ~w(ilclan dark_age late_republic early_republic jihad civil_war clan_invasion)

  schema "master_units" do
    field :mul_id, :integer
    field :name, :string
    field :variant, :string
    field :full_name, :string
    field :unit_type, :string
    field :tonnage, :integer
    field :point_value, :integer
    field :battle_value, :integer
    field :technology_base, :string
    field :rules_level, :string
    field :role, :string
    field :cost, :integer
    field :date_introduced, :integer
    field :era_id, :integer

    # Alpha Strike fields
    field :bf_move, :string
    field :bf_size, :integer
    field :bf_armor, :integer
    field :bf_structure, :integer
    field :bf_damage_short, :string
    field :bf_damage_medium, :string
    field :bf_damage_long, :string
    field :bf_overheat, :integer
    field :bf_abilities, :string

    field :image_url, :string
    field :is_published, :boolean, default: false
    field :last_synced_at, :utc_datetime
    field :factions, :map

    has_many :company_units, CompanyUnit

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(master_unit, attrs) do
    master_unit
    |> cast(attrs, [
      :mul_id,
      :name,
      :variant,
      :full_name,
      :unit_type,
      :tonnage,
      :point_value,
      :battle_value,
      :technology_base,
      :rules_level,
      :role,
      :cost,
      :date_introduced,
      :era_id,
      :bf_move,
      :bf_size,
      :bf_armor,
      :bf_structure,
      :bf_damage_short,
      :bf_damage_medium,
      :bf_damage_long,
      :bf_overheat,
      :bf_abilities,
      :image_url,
      :is_published,
      :last_synced_at,
      :factions
    ])
    |> validate_required([:mul_id, :name, :unit_type])
    |> validate_inclusion(:unit_type, @valid_unit_types)
    |> unique_constraint(:mul_id)
  end

  @doc """
  Returns the list of valid unit types
  """
  def valid_unit_types, do: @valid_unit_types

  @doc """
  Returns a friendly display name for the unit
  """
  def display_name(%__MODULE__{name: name, variant: nil}), do: name
  def display_name(%__MODULE__{name: name, variant: variant}), do: "#{name} #{variant}"

  @doc """
  Returns the MUL website URL for this unit
  """
  def mul_url(%__MODULE__{mul_id: mul_id}), do: "https://www.masterunitlist.info/Unit/Details/#{mul_id}"

  # The SP to PV conversion rate. Units cost 40 SP per point of PV.
  @sp_per_pv 40

  @doc """
  Returns the SP per PV conversion rate.

  This is the standard rate used for:
  - Unit purchase costs (PV × 40)
  - Converting unused PV budget to SP during company finalization

  ## Examples

      iex> sp_per_pv()
      40
  """
  def sp_per_pv, do: @sp_per_pv

  @doc """
  Converts a raw PV value to SP.

  ## Examples

      iex> pv_to_sp(25)
      1000
  """
  def pv_to_sp(pv) when is_integer(pv), do: pv * @sp_per_pv

  @doc """
  Calculates the SP cost to purchase this unit.

  The cost is calculated as Point Value × #{@sp_per_pv} SP.

  ## Examples

      iex> sp_cost(%MasterUnit{point_value: 25})
      1000

      iex> sp_cost(%MasterUnit{point_value: nil})
      nil
  """
  def sp_cost(%__MODULE__{point_value: pv}) when is_integer(pv), do: pv_to_sp(pv)
  def sp_cost(%__MODULE__{point_value: nil}), do: nil

  @doc """
  Calculates the SP sell price for this unit.

  Units sell for half their purchase cost: (Point Value × #{@sp_per_pv}) ÷ 2.

  ## Examples

      iex> sell_price(%MasterUnit{point_value: 25})
      500

      iex> sell_price(%MasterUnit{point_value: nil})
      nil
  """
  def sell_price(%__MODULE__{point_value: pv}) when is_integer(pv), do: div(pv_to_sp(pv), 2)
  def sell_price(%__MODULE__{point_value: nil}), do: nil

  @doc """
  Returns the Sarna.net search URL for this unit
  """
  def sarna_url(%__MODULE__{name: name}) do
    search_term = String.replace(name, " ", "%20")
    "https://www.sarna.net/wiki/Special:Search?search=#{search_term}&go=Go"
  end

  @doc """
  Returns valid era names for faction availability
  """
  def valid_eras, do: @valid_eras

  @doc """
  Checks if a unit is available to a specific faction in a specific era.

  ## Examples

      iex> available_to_faction?(unit, "ilclan", "mercenary")
      true

      iex> available_to_faction?(unit, "dark_age", "clan_wolf")
      false
  """
  def available_to_faction?(%__MODULE__{factions: nil}, _era, _faction), do: false
  def available_to_faction?(%__MODULE__{factions: factions}, era, faction) when is_map(factions) do
    case Map.get(factions, era) do
      nil -> false
      faction_list when is_list(faction_list) -> faction in faction_list
      _ -> false
    end
  end

  @doc """
  Checks if a unit is available to a faction in ANY era.
  """
  def available_to_faction?(%__MODULE__{factions: nil}, _faction), do: false
  def available_to_faction?(%__MODULE__{factions: factions}, faction) when is_map(factions) do
    Enum.any?(factions, fn {_era, faction_list} ->
      is_list(faction_list) and faction in faction_list
    end)
  end

  @doc """
  Returns a list of faction names the unit is available to in a specific era.

  ## Examples

      iex> available_factions(unit, "ilclan")
      ["mercenary", "capellan_confederation"]
  """
  def available_factions(%__MODULE__{factions: nil}, _era), do: []
  def available_factions(%__MODULE__{factions: factions}, era) when is_map(factions) do
    case Map.get(factions, era) do
      faction_list when is_list(faction_list) -> faction_list
      _ -> []
    end
  end

  @doc """
  Returns all unique faction names the unit is available to across all eras.
  """
  def available_factions(%__MODULE__{factions: nil}), do: []
  def available_factions(%__MODULE__{factions: factions}) when is_map(factions) do
    factions
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Returns all eras where this unit has faction availability data.
  """
  def available_eras(%__MODULE__{factions: nil}), do: []
  def available_eras(%__MODULE__{factions: factions}) when is_map(factions) do
    Map.keys(factions)
  end

  @doc """
  Merges new faction availability into existing factions map.
  Used when seeding units multiple times with different era/faction combinations.

  ## Examples

      iex> merge_factions(%{"ilclan" => ["mercenary"]}, "dark_age", ["mercenary", "capellan"])
      %{"ilclan" => ["mercenary"], "dark_age" => ["mercenary", "capellan"]}

      iex> merge_factions(%{"ilclan" => ["mercenary"]}, "ilclan", ["capellan"])
      %{"ilclan" => ["mercenary", "capellan"]}
  """
  def merge_factions(existing_factions, era, new_faction_list) when is_list(new_faction_list) do
    existing_factions = existing_factions || %{}

    existing_for_era = Map.get(existing_factions, era, [])
    merged_for_era = Enum.uniq(existing_for_era ++ new_faction_list)

    Map.put(existing_factions, era, merged_for_era)
  end
end
