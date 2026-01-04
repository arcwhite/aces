defmodule Aces.Units.MasterUnit do
  @moduledoc """
  Schema for master unit list entries from masterunitlist.info
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.CompanyUnit

  @valid_unit_types ~w(battlemech combat_vehicle battle_armor conventional_infantry protomech other)

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
      :bf_armor,
      :bf_structure,
      :bf_damage_short,
      :bf_damage_medium,
      :bf_damage_long,
      :bf_overheat,
      :bf_abilities,
      :image_url,
      :is_published,
      :last_synced_at
    ])
    |> validate_required([:mul_id, :name, :unit_type])
    |> validate_inclusion(:unit_type, @valid_unit_types)
    |> unique_constraint(:mul_id)
  end

  @doc """
  Returns the list of valid unit types
  """
  def valid_unit_types, do: @valid_unit_types
end
