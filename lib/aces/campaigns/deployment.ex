defmodule Aces.Campaigns.Deployment do
  @moduledoc """
  Deployment schema - represents a unit/pilot assignment to a specific sortie
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.{CompanyUnit, Pilot}
  alias Aces.Campaigns.Sortie

  @damage_status ~w(operational armor_damaged structure_damaged crippled salvageable destroyed)
  @casualty_status ~w(none wounded killed)

  schema "deployments" do
    field :configuration_changes, :string
    field :configuration_cost_sp, :integer, default: 0

    # Post-battle status
    field :damage_status, :string
    field :pilot_casualty, :string, default: "none"
    field :was_salvaged, :boolean, default: false
    field :repair_cost_sp, :integer, default: 0
    field :casualty_cost_sp, :integer, default: 0

    belongs_to :sortie, Sortie
    belongs_to :company_unit, CompanyUnit
    belongs_to :pilot, Pilot

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :configuration_changes, :configuration_cost_sp, :damage_status,
      :pilot_casualty, :was_salvaged, :repair_cost_sp, :casualty_cost_sp
    ])
    |> validate_inclusion(:damage_status, @damage_status)
    |> validate_inclusion(:pilot_casualty, @casualty_status)
    |> validate_number(:configuration_cost_sp, greater_than_or_equal_to: 0)
    |> validate_number(:repair_cost_sp, greater_than_or_equal_to: 0)
    |> validate_number(:casualty_cost_sp, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:sortie_id)
    |> foreign_key_constraint(:company_unit_id)
    |> foreign_key_constraint(:pilot_id)
  end

  def creation_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [:sortie_id, :company_unit_id, :pilot_id, :configuration_changes, :configuration_cost_sp])
    |> validate_required([:sortie_id, :company_unit_id])
    |> validate_number(:configuration_cost_sp, greater_than_or_equal_to: 0)
    |> put_change(:damage_status, "operational")
    |> put_change(:pilot_casualty, "none")
    |> unique_constraint([:sortie_id, :company_unit_id])
    |> foreign_key_constraint(:sortie_id)
    |> foreign_key_constraint(:company_unit_id)
    |> foreign_key_constraint(:pilot_id)
  end

  def post_battle_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [:damage_status, :pilot_casualty, :was_salvaged])
    |> validate_required([:damage_status, :pilot_casualty])
    |> validate_inclusion(:damage_status, @damage_status)
    |> validate_inclusion(:pilot_casualty, @casualty_status)
    |> calculate_repair_costs()
    |> calculate_casualty_costs()
  end

  defp calculate_repair_costs(changeset) do
    case {get_field(changeset, :company_unit), get_change(changeset, :damage_status)} do
      {%{master_unit: master_unit}, damage_status} when damage_status != nil ->
        repair_cost = calculate_unit_repair_cost(master_unit, damage_status)
        put_change(changeset, :repair_cost_sp, repair_cost)

      _ ->
        changeset
    end
  end

  defp calculate_casualty_costs(changeset) do
    case get_change(changeset, :pilot_casualty) do
      casualty when casualty in ["wounded", "killed"] ->
        put_change(changeset, :casualty_cost_sp, 100)

      _ ->
        put_change(changeset, :casualty_cost_sp, 0)
    end
  end

  @doc """
  Calculate repair cost based on unit size and damage status
  Following CAMPAIGNS.md rules
  """
  def calculate_unit_repair_cost(master_unit, damage_status) do
    repair_size = get_repair_size(master_unit)

    case damage_status do
      "destroyed" -> 0  # Cannot be repaired
      "salvageable" -> round(repair_size * 100)
      "crippled" -> round(repair_size * 60)
      "structure_damaged" -> round(repair_size * 40)
      "armor_damaged" -> round(repair_size * 20)
      "operational" -> 0
      _ -> 0
    end
  end

  @doc """
  Get the effective size for repair cost calculations.
  Combat Vehicles, Battle Armour, and Infantry count as half size.
  """
  def get_repair_size(%{unit_type: unit_type, bf_size: bf_size}) do
    # Use bf_size from MUL API, defaulting to 1 if not available
    base_size = bf_size || 1

    # Combat Vehicles, Battle Armour, and Infantry count as half size for repair costs
    case unit_type do
      type when type in ["combat_vehicle", "battle_armor", "conventional_infantry"] ->
        base_size / 2.0

      _ ->
        base_size
    end
  end

  @doc """
  Check if unit needs rearming (ENE special ability exempts from rearming costs)
  """
  def needs_rearming?(%__MODULE__{company_unit: %{master_unit: master_unit}}) do
    abilities = master_unit.bf_abilities || ""
    not String.contains?(abilities, "ENE")
  end

  def needs_rearming?(_), do: true

  @doc """
  Get rearming cost for this deployment (20 SP unless ENE)
  """
  def get_rearming_cost(deployment) do
    if needs_rearming?(deployment), do: 20, else: 0
  end
end
