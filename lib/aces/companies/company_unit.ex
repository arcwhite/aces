defmodule Aces.Companies.CompanyUnit do
  @moduledoc """
  Schema for units in a company's roster
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.Company
  alias Aces.Companies.Pilot
  alias Aces.Units.MasterUnit

  defmodule ValidationErrors do
    @moduledoc """
    Centralized error messages for validation consistency
    """

    def company_not_draft(status), do: "Cannot add units to #{status} companies"
    def company_not_found, do: "Company not found"
    def master_unit_not_found, do: "Master unit not found"

    def unit_type_not_allowed(allowed_types) do
      formatted_types = allowed_types
        |> Enum.map(&String.replace(&1, "_", " "))
        |> Enum.map(&String.split(&1, " "))
        |> Enum.map(fn words -> Enum.map(words, &String.capitalize/1) end)
        |> Enum.map(&Enum.join(&1, " "))
        |> Enum.join(", ")
      "Only types #{formatted_types} are allowed"
    end

    def insufficient_pv_budget(needed, available) do
      "Insufficient PV budget. Need #{needed} PV, but only #{available} remaining"
    end

    def max_chassis_exceeded, do: "Cannot add more than 2 Battlemechs of the same chassis"
    def duplicate_variant, do: "Cannot add duplicate Battlemech variants of the same chassis"
    def max_identical_units_exceeded, do: "Cannot add more than 2 identical units of the same type"
  end

  @valid_statuses ~w(operational damaged destroyed salvaged)
  @allowed_unit_types ~w(battlemech battle_armor combat_vehicle conventional_infantry)
  @max_chassis_count 2
  @max_identical_units 2

  schema "company_units" do
    field :custom_name, :string
    field :status, :string, default: "operational"
    field :purchase_cost_sp, :integer, default: 0

    belongs_to :company, Company
    belongs_to :master_unit, MasterUnit
    belongs_to :pilot, Pilot

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(company_unit, attrs) do
    company_unit
    |> cast(attrs, [:company_id, :master_unit_id, :custom_name, :status, :purchase_cost_sp, :pilot_id])
    |> validate_required([:company_id, :master_unit_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:purchase_cost_sp, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:master_unit_id)
    |> foreign_key_constraint(:pilot_id)
  end

  @doc """
  Changeset for adding units to draft companies with business rule validations
  """
  def draft_company_changeset(company_unit, attrs) do
    company_unit
    |> changeset(attrs)
    |> validate_company_is_draft()
    |> validate_unit_type_allowed()
    |> validate_pv_budget()
    |> validate_unit_composition_limits()
  end

  # Higher-order function to eliminate repetitive validation pattern
  defp validate_when_valid(changeset, validation_fn) do
    if changeset.valid?, do: validation_fn.(changeset), else: changeset
  end

  defp validate_company_is_draft(changeset) do
    validate_when_valid(changeset, fn changeset ->
      case get_company(changeset) do
        %Company{status: "draft"} ->
          changeset

        %Company{status: status} ->
          add_error(changeset, :company_id, ValidationErrors.company_not_draft(status))

        nil ->
          add_error(changeset, :company_id, ValidationErrors.company_not_found())
      end
    end)
  end

  defp validate_unit_type_allowed(changeset) do
    validate_when_valid(changeset, fn changeset ->
      case get_master_unit(changeset) do
        %MasterUnit{unit_type: unit_type} when unit_type in @allowed_unit_types ->
          changeset

        %MasterUnit{} ->
          add_error(changeset, :master_unit_id, ValidationErrors.unit_type_not_allowed(@allowed_unit_types))

        nil ->
          add_error(changeset, :master_unit_id, ValidationErrors.master_unit_not_found())
      end
    end)
  end

  defp validate_pv_budget(changeset) do
    validate_when_valid(changeset, fn changeset ->
      with %Company{} = company <- get_company(changeset),
           %MasterUnit{} = master_unit <- get_master_unit(changeset) do

        current_pv_used = Aces.Companies.calculate_company_pv_usage(company)
        unit_cost = master_unit.point_value || 0
        available_pv = company.pv_budget - current_pv_used

        if unit_cost <= available_pv do
          changeset
        else
          add_error(changeset, :master_unit_id,
            ValidationErrors.insufficient_pv_budget(unit_cost, available_pv))
        end
      else
        _ -> changeset  # Errors will be caught by other validations
      end
    end)
  end

  defp validate_unit_composition_limits(changeset) do
    validate_when_valid(changeset, fn changeset ->
      with %Company{} = company <- get_company(changeset),
           %MasterUnit{} = master_unit <- get_master_unit(changeset) do
        case master_unit.unit_type do
          "battlemech" -> validate_battlemech_limits(changeset, company, master_unit)
          _ -> validate_non_battlemech_limits(changeset, company, master_unit)
        end
      else
        _ -> changeset  # Errors caught by other validations
      end
    end)
  end

  defp validate_battlemech_limits(changeset, company, master_unit) do
    existing_battlemechs = get_existing_units_by_chassis(company, master_unit)
    all_battlemechs = get_all_battlemechs(company)
    paired_chassis = get_paired_chassis(all_battlemechs)

    target_chassis = extract_chassis_from_name(master_unit)

    cond do
      has_duplicate_variant?(existing_battlemechs, master_unit) ->
        add_error(changeset, :master_unit_id, ValidationErrors.duplicate_variant())

      length(existing_battlemechs) >= @max_chassis_count ->
        add_error(changeset, :master_unit_id, ValidationErrors.max_chassis_exceeded())

      # Check if adding this would create a second paired chassis:
      # Only prevent when we already have 1 mech of this chassis AND there's already a paired chassis in the company
      length(existing_battlemechs) == 1 and length(paired_chassis) > 0 and target_chassis not in paired_chassis ->
        add_error(changeset, :master_unit_id, "Cannot add more than one pair of Mechs with the same chassis. Company already has a paired chassis.")

      true ->
        changeset
    end
  end

  defp validate_non_battlemech_limits(changeset, company, master_unit) do
    identical_units = get_identical_units(company, master_unit)

    if length(identical_units) >= @max_identical_units do
      add_error(changeset, :master_unit_id, ValidationErrors.max_identical_units_exceeded())
    else
      changeset
    end
  end

  defp has_duplicate_variant?(existing_battlemechs, master_unit) do
    Enum.any?(existing_battlemechs, &(&1.master_unit.variant == master_unit.variant))
  end

  defp get_company(changeset) do
    company_id = get_field(changeset, :company_id)
    if company_id, do: Aces.Companies.get_company!(company_id), else: nil
  end

  defp get_master_unit(changeset) do
    master_unit_id = get_field(changeset, :master_unit_id)
    if master_unit_id, do: Aces.Repo.get(MasterUnit, master_unit_id), else: nil
  end

  # Optimized helper functions for validation
  defp get_existing_units_by_chassis(%Company{company_units: units}, %MasterUnit{} = master_unit) do
    target_chassis = extract_chassis_from_name(master_unit)

    Enum.filter(units, fn unit ->
      unit.master_unit &&
      unit.master_unit.unit_type == "battlemech" &&
      extract_chassis_from_name(unit.master_unit) == target_chassis
    end)
  end

  # Extracts the chassis name by removing the variant suffix from the full name.
  # Examples:
  #   "Fenris (Ice Ferret) E" with variant "E" -> "Fenris (Ice Ferret)"
  #   "Fenris (Ice Ferret)" with variant "Prime" -> "Fenris (Ice Ferret)"
  #   "BattleMaster BLR-4S" with variant "BLR-4S" -> "BattleMaster"
  defp extract_chassis_from_name(%MasterUnit{name: name, variant: variant})
       when is_binary(name) and is_binary(variant) do
    name
    |> String.trim_trailing(" " <> variant)
    |> String.trim()
  end

  defp extract_chassis_from_name(%MasterUnit{name: name}) when is_binary(name), do: name
  defp extract_chassis_from_name(_), do: nil

  defp get_all_battlemechs(%Company{company_units: units}) do
    Enum.filter(units, fn unit ->
      unit.master_unit && unit.master_unit.unit_type == "battlemech"
    end)
  end

  defp get_paired_chassis(battlemechs) do
    battlemechs
    |> Enum.group_by(fn unit -> extract_chassis_from_name(unit.master_unit) end)
    |> Enum.filter(fn {_chassis, units} -> length(units) >= 2 end)
    |> Enum.map(fn {chassis, _units} -> chassis end)
  end

  defp get_identical_units(%Company{company_units: units}, %MasterUnit{} = master_unit) do
    Enum.filter(units, fn unit ->
      unit.master_unit && units_match?(unit.master_unit, master_unit)
    end)
  end

  defp units_match?(%MasterUnit{} = unit1, %MasterUnit{} = unit2) do
    unit1.name == unit2.name &&
    unit1.variant == unit2.variant &&
    unit1.unit_type == unit2.unit_type
  end

  @doc """
  Returns the list of valid statuses
  """
  def valid_statuses, do: @valid_statuses

  @doc """
  Returns the effective skill level for a unit.
  If a pilot is assigned, returns the pilot's skill level.
  If no pilot is assigned, returns default skill level of 4.
  """
  def effective_skill_level(%__MODULE__{pilot: %Pilot{skill_level: skill_level}}), do: skill_level
  def effective_skill_level(%__MODULE__{pilot: nil}), do: 4
  def effective_skill_level(%__MODULE__{pilot: _not_loaded}), do: 4
end
