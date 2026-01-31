defmodule Aces.Companies do
  @moduledoc """
  The Companies context - business logic for mercenary company management.

  For unit roster management, see `Aces.Companies.Units`.
  For pilot management, see `Aces.Companies.Pilots`.
  """

  # Dialyzer false positive: Ecto.Multi opaque type warnings when piping
  @dialyzer :no_opaque

  import Ecto.Query, warn: false
  alias Aces.Repo

  alias Aces.Accounts.User
  alias Aces.Companies.{Company, CompanyMembership}
  alias Aces.Units.MasterUnit

  ## Company CRUD

  @doc """
  Returns the list of companies for a given user.
  """
  def list_user_companies(%User{} = user) do
    from(c in Company,
      join: m in CompanyMembership,
      on: m.company_id == c.id,
      where: m.user_id == ^user.id,
      preload: [:memberships, :pilots, company_units: :master_unit],
      order_by: [desc: c.updated_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of active companies for a given user.
  """
  def list_user_active_companies(%User{} = user) do
    from(c in Company,
      join: m in CompanyMembership,
      on: m.company_id == c.id,
      where: m.user_id == ^user.id and c.status == "active",
      preload: [:memberships, :pilots, company_units: :master_unit],
      order_by: [desc: c.updated_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of draft companies for a given user.
  """
  def list_user_draft_companies(%User{} = user) do
    from(c in Company,
      join: m in CompanyMembership,
      on: m.company_id == c.id,
      where: m.user_id == ^user.id and c.status == "draft",
      preload: [:memberships, :pilots, company_units: :master_unit],
      order_by: [desc: c.updated_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of companies for a given user with stats.
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
    |> preload([:memberships, company_units: [:master_unit, :pilot], pilots: [assigned_unit: :master_unit]])
    |> Repo.get!(id)
    |> sort_company_units()
  end

  @doc """
  Gets a single company with stats.
  """
  def get_company_with_stats!(id) do
    id
    |> get_company!()
    |> add_company_stats()
  end

  @doc """
  Creates a company and adds the creator as owner.
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
  Finalizes a company, converting unused PV to SP at a 1:#{MasterUnit.sp_per_pv()} ratio
  and setting status to active.
  """
  def finalize_company(%Company{} = company) do
    company_with_stats = add_company_stats(company)
    unused_pv = company_with_stats.stats.pv_remaining
    bonus_sp = MasterUnit.pv_to_sp(unused_pv)

    attrs = %{
      status: "active",
      warchest_balance: company.warchest_balance + bonus_sp
    }

    company
    |> Company.changeset(attrs)
    |> validate_can_finalize()
    |> Repo.update()
  end

  defp validate_can_finalize(changeset) do
    company = changeset.data

    changeset
    |> validate_is_draft(company)
    |> validate_minimum_pilots(company)
    |> validate_minimum_units(company)
  end

  defp validate_is_draft(changeset, company) do
    if company.status != "draft" do
      Ecto.Changeset.add_error(changeset, :status, "company is already #{company.status}, cannot finalize")
    else
      changeset
    end
  end

  defp validate_minimum_pilots(changeset, company) do
    pilot_count = if company.pilots, do: length(company.pilots), else: 0

    if pilot_count < 2 do
      Ecto.Changeset.add_error(changeset, :pilots, "company must have at least 2 named pilots to finalize")
    else
      changeset
    end
  end

  defp validate_minimum_units(changeset, company) do
    unit_count = if company.company_units, do: length(company.company_units), else: 0

    if unit_count < 8 do
      Ecto.Changeset.add_error(changeset, :company_units, "company must have at least 8 units to finalize")
    else
      changeset
    end
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
  Adds a user to a company with a specific role.
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
  Updates a member's role.
  """
  def update_member_role(%CompanyMembership{} = membership, role) do
    membership
    |> CompanyMembership.changeset(%{role: role})
    |> Repo.update()
  end

  @doc """
  Removes a user from a company.
  """
  def remove_member(%CompanyMembership{} = membership) do
    Repo.delete(membership)
  end

  @doc """
  Gets a user's membership for a company.
  """
  def get_membership(%Company{} = company, %User{} = user) do
    Repo.get_by(CompanyMembership, company_id: company.id, user_id: user.id)
  end

  @doc """
  Gets a user's role for a company.
  """
  def get_user_role(%Company{} = company, %User{} = user) do
    case get_membership(company, user) do
      nil -> nil
      membership -> membership.role
    end
  end

  ## Helper Functions

  @doc """
  Calculate total PV usage for a company.
  """
  def calculate_company_pv_usage(%Company{} = company) do
    company.company_units
    |> Enum.map(fn unit ->
      if unit.master_unit do
        unit.master_unit.point_value || 0
      else
        0
      end
    end)
    |> Enum.sum()
  end

  defp add_company_stats(company) do
    unit_count = length(company.company_units)
    pv_used = calculate_company_pv_usage(company)
    pv_remaining = company.pv_budget - pv_used
    pilot_count = if company.pilots, do: length(company.pilots), else: 0

    Map.merge(company, %{
      stats: %{
        unit_count: unit_count,
        pilot_count: pilot_count,
        warchest_balance: company.warchest_balance,
        pv_used: pv_used,
        pv_remaining: pv_remaining,
        pv_budget: company.pv_budget,
        last_modified: company.updated_at
      }
    })
  end

  defp sort_company_units(%Company{company_units: units} = company) do
    sorted_units =
      units
      |> Enum.sort_by(fn unit ->
        if unit.master_unit do
          {unit.master_unit.unit_type, unit.master_unit.point_value || 0}
        else
          {"", 0}
        end
      end)

    %{company | company_units: sorted_units}
  end
end
