defmodule Aces.Companies.Units do
  @moduledoc """
  Unit roster management for mercenary companies.
  """

  import Ecto.Query, warn: false
  alias Aces.Repo

  alias Aces.Companies.CompanyUnit
  alias Aces.Companies.Company
  alias Aces.Units

  @doc """
  Adds a unit to a company's roster with PV budget checking.
  Only available for draft companies.
  """
  def add_unit_to_company(%Company{} = company, mul_id, attrs \\ %{}) do
    case Units.get_master_unit_by_mul_id(mul_id) do
      {:ok, master_unit} ->
        unit_attrs = Map.merge(attrs, %{
          company_id: company.id,
          master_unit_id: master_unit.id
        })

        %CompanyUnit{}
        |> CompanyUnit.draft_company_changeset(unit_attrs)
        |> Repo.insert()

      {:error, :not_found} ->
        {:error, unit_lookup_error_changeset("Unit not found in Master Unit List")}

      {:error, reason} ->
        {:error, unit_lookup_error_changeset("Failed to lookup unit: #{reason}")}
    end
  end

  @doc """
  Purchase a unit for a company (includes PV budget deduction).
  Only available for draft companies.
  """
  def purchase_unit_for_company(%Company{} = company, mul_id, attrs \\ %{}) do
    case Units.get_master_unit_by_mul_id(mul_id) do
      {:ok, master_unit} ->
        unit_attrs = Map.merge(attrs, %{
          company_id: company.id,
          master_unit_id: master_unit.id,
          purchase_cost_sp: attrs[:purchase_cost_sp] || 0
        })

        %CompanyUnit{}
        |> CompanyUnit.draft_company_changeset(unit_attrs)
        |> Repo.insert()
        |> case do
          {:ok, company_unit} -> {:ok, Repo.preload(company_unit, :master_unit)}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, :not_found} ->
        {:error, unit_lookup_error_changeset("Unit not found in Master Unit List")}

      {:error, reason} ->
        {:error, unit_lookup_error_changeset("Failed to lookup unit: #{reason}")}
    end
  end

  @doc """
  Removes a unit from a company's roster.
  """
  def remove_unit_from_company(%CompanyUnit{} = company_unit) do
    Repo.delete(company_unit)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking company unit changes.
  """
  def change_company_unit(%CompanyUnit{} = company_unit, attrs \\ %{}) do
    CompanyUnit.changeset(company_unit, attrs)
  end

  @doc """
  Updates a company unit.
  """
  def update_company_unit(%CompanyUnit{} = company_unit, attrs) do
    company_unit
    |> CompanyUnit.changeset(attrs)
    |> Repo.update()
  end

  defp unit_lookup_error_changeset(message) do
    %CompanyUnit{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:master_unit_id, message)
  end
end
