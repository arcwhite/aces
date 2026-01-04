defmodule Aces.Companies do
  @moduledoc """
  The Companies context - business logic for mercenary company management
  """

  import Ecto.Query, warn: false
  alias Aces.Repo

  alias Aces.Accounts.User
  alias Aces.Companies.{Company, CompanyMembership, CompanyUnit}
  alias Aces.Units.MasterUnit

  ## Company CRUD

  @doc """
  Returns the list of companies for a given user
  """
  def list_user_companies(%User{} = user) do
    from(c in Company,
      join: m in CompanyMembership,
      on: m.company_id == c.id,
      where: m.user_id == ^user.id,
      preload: [:memberships, :company_units],
      order_by: [desc: c.updated_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of companies for a given user with stats
  """
  def list_user_companies_with_stats(%User{} = user) do
    user
    |> list_user_companies()
    |> Enum.map(&add_company_stats/1)
  end

  @doc """
  Gets a single company.
  Raises `Ecto.NoResultsError` if the Company does not exist.
  """
  def get_company!(id) do
    Company
    |> preload([:memberships, :company_units, company_units: :master_unit])
    |> Repo.get!(id)
  end

  @doc """
  Gets a single company with stats
  """
  def get_company_with_stats!(id) do
    id
    |> get_company!()
    |> add_company_stats()
  end

  @doc """
  Creates a company and adds the creator as owner
  """
  def create_company(attrs \\ %{}, %User{} = creator) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:company, Company.creation_changeset(%Company{}, attrs))
    |> Ecto.Multi.insert(:membership, fn %{company: company} ->
      CompanyMembership.changeset(%CompanyMembership{}, %{
        user_id: creator.id,
        company_id: company.id,
        role: "owner"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{company: company, membership: _membership}} ->
        {:ok, get_company!(company.id)}

      {:error, :company, changeset, _} ->
        {:error, changeset}

      {:error, :membership, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates a company.
  """
  def update_company(%Company{} = company, attrs) do
    company
    |> Company.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a company.
  """
  def delete_company(%Company{} = company) do
    Repo.delete(company)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking company changes.
  """
  def change_company(%Company{} = company, attrs \\ %{}) do
    Company.changeset(company, attrs)
  end

  ## Company Memberships

  @doc """
  Adds a user to a company with a specific role
  """
  def add_member(%Company{} = company, %User{} = user, role \\ "viewer") do
    %CompanyMembership{}
    |> CompanyMembership.changeset(%{
      user_id: user.id,
      company_id: company.id,
      role: role
    })
    |> Repo.insert()
  end

  @doc """
  Updates a member's role
  """
  def update_member_role(%CompanyMembership{} = membership, role) do
    membership
    |> CompanyMembership.changeset(%{role: role})
    |> Repo.update()
  end

  @doc """
  Removes a user from a company
  """
  def remove_member(%CompanyMembership{} = membership) do
    Repo.delete(membership)
  end

  @doc """
  Gets a user's membership for a company
  """
  def get_membership(%Company{} = company, %User{} = user) do
    Repo.get_by(CompanyMembership, company_id: company.id, user_id: user.id)
  end

  @doc """
  Gets a user's role for a company
  """
  def get_user_role(%Company{} = company, %User{} = user) do
    case get_membership(company, user) do
      nil -> nil
      membership -> membership.role
    end
  end

  ## Company Units

  @doc """
  Adds a unit to a company's roster
  """
  def add_unit_to_company(%Company{} = company, mul_id, attrs \\ %{}) do
    # For now, we'll create a simple master_unit entry
    # Later this will integrate with the MUL API
    master_unit = get_or_create_master_unit(mul_id, attrs)

    %CompanyUnit{}
    |> CompanyUnit.changeset(
      Map.merge(attrs, %{
        company_id: company.id,
        master_unit_id: master_unit.id
      })
    )
    |> Repo.insert()
  end

  @doc """
  Removes a unit from a company's roster
  """
  def remove_unit_from_company(%CompanyUnit{} = company_unit) do
    Repo.delete(company_unit)
  end

  @doc """
  Updates a company unit
  """
  def update_company_unit(%CompanyUnit{} = company_unit, attrs) do
    company_unit
    |> CompanyUnit.changeset(attrs)
    |> Repo.update()
  end

  ## Helper Functions

  defp add_company_stats(company) do
    unit_count = length(company.company_units)

    Map.merge(company, %{
      stats: %{
        unit_count: unit_count,
        warchest_balance: company.warchest_balance,
        last_modified: company.updated_at
      }
    })
  end

  defp get_or_create_master_unit(mul_id, attrs) do
    case Repo.get_by(MasterUnit, mul_id: mul_id) do
      nil ->
        # Create a simple master unit entry
        # In the future, this will fetch from MUL API
        {:ok, master_unit} =
          %MasterUnit{}
          |> MasterUnit.changeset(
            Map.merge(
              %{
                mul_id: mul_id,
                name: attrs[:name] || "Unknown Unit",
                unit_type: attrs[:unit_type] || "battlemech",
                point_value: attrs[:point_value] || 0
              },
              attrs
            )
          )
          |> Repo.insert()

        master_unit

      master_unit ->
        master_unit
    end
  end
end
