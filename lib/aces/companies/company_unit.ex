defmodule Aces.Companies.CompanyUnit do
  @moduledoc """
  Schema for units in a company's roster
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.Company
  alias Aces.Units.MasterUnit

  @valid_statuses ~w(operational damaged destroyed salvaged)

  schema "company_units" do
    field :custom_name, :string
    field :status, :string, default: "operational"
    field :purchase_cost_sp, :integer, default: 0

    belongs_to :company, Company
    belongs_to :master_unit, MasterUnit

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(company_unit, attrs) do
    company_unit
    |> cast(attrs, [:company_id, :master_unit_id, :custom_name, :status, :purchase_cost_sp])
    |> validate_required([:company_id, :master_unit_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:purchase_cost_sp, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:master_unit_id)
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

  defp validate_company_is_draft(changeset) do
    if changeset.valid? do
      case get_field(changeset, :company_id) do
        nil -> changeset # Will be caught by validate_required
        company_id ->
          case Aces.Repo.get(Company, company_id) do
            %Company{status: "draft"} ->
              changeset

            %Company{status: status} ->
              add_error(changeset, :company_id, "Cannot add units to #{status} companies")

            nil ->
              add_error(changeset, :company_id, "Company not found")
          end
      end
    else
      changeset
    end
  end

  defp validate_unit_type_allowed(changeset) do
    if changeset.valid? do
      case get_master_unit(changeset) do
        %MasterUnit{} = master_unit ->
          allowed_types = ["battlemech", "battle_armor", "combat_vehicle", "conventional_infantry"]

          if master_unit.unit_type in allowed_types do
            changeset
          else
            add_error(changeset, :master_unit_id,
              "Only Battlemechs, Battle Armor, Combat Vehicles, and Conventional Infantry are allowed")
          end

        nil ->
          add_error(changeset, :master_unit_id, "Master unit not found")
      end
    else
      changeset
    end
  end

  defp validate_pv_budget(changeset) do
    if changeset.valid? do
      with %Company{} = company <- get_company(changeset),
           %MasterUnit{} = master_unit <- get_master_unit(changeset) do

        current_pv_used = Aces.Companies.calculate_company_pv_usage(company)
        unit_cost = master_unit.point_value || 0
        available_pv = company.pv_budget - current_pv_used

        if unit_cost <= available_pv do
          changeset
        else
          add_error(changeset, :master_unit_id,
            "Insufficient PV budget. Need #{unit_cost} PV, but only #{available_pv} remaining")
        end
      else
        _ -> changeset  # Errors will be caught by other validations
      end
    else
      changeset
    end
  end

  defp validate_unit_composition_limits(changeset) do
    if changeset.valid? do
      with %Company{} = company <- get_company(changeset),
           %MasterUnit{unit_type: "battlemech"} = master_unit <- get_master_unit(changeset) do
        
        # Battlemech-specific validation: max 2 of same chassis, different variants
        existing_battlemechs = get_existing_units_by_chassis(company, master_unit)
        
        cond do
          length(existing_battlemechs) >= 2 ->
            add_error(changeset, :master_unit_id, "Cannot add more than 2 Battlemechs of the same chassis")
          
          Enum.any?(existing_battlemechs, &(&1.master_unit.variant == master_unit.variant)) ->
            add_error(changeset, :master_unit_id, "Cannot add duplicate Battlemech variants of the same chassis")
          
          true ->
            changeset
        end
      else
        %MasterUnit{} = master_unit ->
          # Non-battlemech validation: max 2 identical units
          company = get_company(changeset)
          identical_units = get_identical_units(company, master_unit)
          
          if length(identical_units) >= 2 do
            add_error(changeset, :master_unit_id, "Cannot add more than 2 identical units of the same type")
          else
            changeset
          end
        
        _ -> changeset  # Errors will be caught by other validations
      end
    else
      changeset
    end
  end

  # Helper functions for validation
  defp get_existing_units_by_chassis(%Company{} = company, %MasterUnit{} = master_unit) do
    company.company_units
    |> Enum.filter(&(&1.master_unit && &1.master_unit.unit_type == "battlemech"))
    |> Enum.filter(&(&1.master_unit.name == master_unit.name))
  end

  defp get_identical_units(%Company{} = company, %MasterUnit{} = master_unit) do
    company.company_units
    |> Enum.filter(fn cu ->
      cu.master_unit &&
      cu.master_unit.name == master_unit.name &&
      cu.master_unit.variant == master_unit.variant &&
      cu.master_unit.unit_type == master_unit.unit_type
    end)
  end

  defp get_company(changeset) do
    company_id = get_field(changeset, :company_id)
    if company_id, do: Aces.Companies.get_company!(company_id), else: nil
  end

  defp get_master_unit(changeset) do
    master_unit_id = get_field(changeset, :master_unit_id)
    if master_unit_id, do: Aces.Repo.get(MasterUnit, master_unit_id), else: nil
  end

  @doc """
  Returns the list of valid statuses
  """
  def valid_statuses, do: @valid_statuses
end
