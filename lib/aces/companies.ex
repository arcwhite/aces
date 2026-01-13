defmodule Aces.Companies do
  @moduledoc """
  The Companies context - business logic for mercenary company management
  """

  import Ecto.Query, warn: false
  alias Aces.Repo

  alias Aces.Accounts.User
  alias Aces.Companies.{Company, CompanyMembership, CompanyUnit, Pilot}
  alias Aces.Units

  ## Company CRUD

  @doc """
  Returns the list of companies for a given user
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
  Returns the list of active companies for a given user
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
  Returns the list of draft companies for a given user
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
    |> preload([:memberships, company_units: [:master_unit, :pilot], pilots: [assigned_unit: :master_unit]])
    |> Repo.get!(id)
    |> sort_company_units()
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
  Finalizes a company, converting unused PV to SP at a 1:40 ratio
  and setting status to active
  """
  def finalize_company(%Company{} = company) do
    company_with_stats = add_company_stats(company)
    unused_pv = company_with_stats.stats.pv_remaining
    bonus_sp = unused_pv * 40

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
    original_status = changeset.data.status

    if original_status != "draft" do
      Ecto.Changeset.add_error(changeset, :status, "company is already #{original_status}, cannot finalize")
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
  Adds a unit to a company's roster with PV budget checking
  Only available for draft companies
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
  Purchase a unit for a company (includes PV budget deduction)
  Only available for draft companies
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

  defp unit_lookup_error_changeset(message) do
    %CompanyUnit{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:master_unit_id, message)
  end

  @doc """
  Removes a unit from a company's roster
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
  Updates a company unit
  """
  def update_company_unit(%CompanyUnit{} = company_unit, attrs) do
    company_unit
    |> CompanyUnit.changeset(attrs)
    |> Repo.update()
  end

  ## Helper Functions

  @doc """
  Calculate total PV usage for a company
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

  ## Pilot Management

  @doc """
  Creates a pilot for a company
  """
  def create_pilot(%Company{} = company, attrs \\ %{}) do
    %Pilot{}
    |> Pilot.changeset(Map.put(attrs, :company_id, company.id))
    |> validate_pilot_limit(company)
    |> Repo.insert()
  end

  defp validate_pilot_limit(changeset, %Company{status: "draft", pilots: pilots}) do
    if length(pilots || []) >= 6 do
      Ecto.Changeset.add_error(changeset, :base, "cannot add more than 6 pilots during company creation")
    else
      changeset
    end
  end

  defp validate_pilot_limit(changeset, _company), do: changeset

  @doc """
  Creates multiple pilots for a company (used during company creation)
  """
  def create_pilots(%Company{} = company, pilots_attrs) when is_list(pilots_attrs) do
    if length(pilots_attrs) > 6 do
      changeset =
        %Pilot{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:base, "cannot add more than 6 pilots during company creation")

      {:error, changeset}
    else
      Ecto.Multi.new()
      |> Ecto.Multi.run(:pilots, fn _repo, _changes ->
        pilots_with_company_id = 
          pilots_attrs
          |> Enum.with_index()
          |> Enum.map(fn {attrs, index} ->
            changeset = Pilot.changeset(%Pilot{}, Map.put(attrs, :company_id, company.id))
            {:"pilot_#{index}", changeset}
          end)

        multi = Enum.reduce(pilots_with_company_id, Ecto.Multi.new(), fn {name, changeset}, acc ->
          Ecto.Multi.insert(acc, name, changeset)
        end)

        case Repo.transaction(multi) do
          {:ok, results} ->
            pilots = 
              results
              |> Map.values()
              |> Enum.filter(&is_struct(&1, Pilot))
            {:ok, pilots}
          {:error, _name, changeset, _changes} ->
            {:error, changeset}
        end
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{pilots: pilots}} -> {:ok, pilots}
        {:error, :pilots, error} -> {:error, error}
      end
    end
  end

  @doc """
  Updates a pilot
  """
  def update_pilot(%Pilot{} = pilot, attrs) do
    pilot
    |> Pilot.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a pilot
  """
  def delete_pilot(%Pilot{} = pilot) do
    Repo.delete(pilot)
  end

  @doc """
  Gets a pilot by ID
  """
  def get_pilot!(id) do
    Repo.get!(Pilot, id)
  end

  @doc """
  Gets pilots for a company
  """
  def list_company_pilots(%Company{id: company_id}) do
    from(p in Pilot,
      where: p.company_id == ^company_id,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  @doc """
  Gets active pilots for a company (deployable)
  """
  def list_active_company_pilots(%Company{id: company_id}) do
    from(p in Pilot,
      where: p.company_id == ^company_id and p.status == "active" and p.wounds < 3,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  @hiring_cost 150

  @doc """
  Hire a new pilot for an active company (SP cost)
  """
  def hire_pilot(%Company{} = company, attrs \\ %{}) do
    changeset =
      %Pilot{}
      |> Pilot.changeset(Map.put(attrs, :company_id, company.id))
      |> validate_company_active_for_hiring(company)
      |> validate_sufficient_funds_for_hiring(company)

    if changeset.valid? do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:pilot, changeset)
      |> Ecto.Multi.update(:company, Company.changeset(company, %{warchest_balance: company.warchest_balance - @hiring_cost}))
      |> Repo.transaction()
      |> case do
        {:ok, %{pilot: pilot, company: updated_company}} ->
          {:ok, pilot, updated_company}
        {:error, :pilot, changeset, _} ->
          {:error, changeset}
        {:error, :company, changeset, _} ->
          {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  defp validate_company_active_for_hiring(changeset, %Company{status: "active"}), do: changeset
  defp validate_company_active_for_hiring(changeset, %Company{status: status}) do
    Ecto.Changeset.add_error(changeset, :base, "cannot hire pilots for #{status} companies, only active companies can hire pilots")
  end

  defp validate_sufficient_funds_for_hiring(changeset, %Company{warchest_balance: balance}) do
    if balance >= @hiring_cost do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :base, "insufficient SP to hire pilot (need #{@hiring_cost} SP, have #{balance} SP)")
    end
  end

  @doc """
  Apply wounds to a pilot and update their status
  """
  def wound_pilot(%Pilot{} = pilot, severity \\ 1) do
    wounded_pilot = Pilot.apply_wound(pilot, severity)
    update_pilot(pilot, %{wounds: wounded_pilot.wounds, status: wounded_pilot.status})
  end

  @doc """
  Award MVP bonus to a pilot (+20 SP)
  """
  def award_mvp(%Pilot{} = pilot) do
    update_pilot(pilot, %{
      sp_earned: pilot.sp_earned + 20,
      mvp_awards: pilot.mvp_awards + 1
    })
  end

  @doc """
  Award SP to a pilot
  """
  def award_sp(%Pilot{} = pilot, sp_amount) when is_integer(sp_amount) and sp_amount > 0 do
    update_pilot(pilot, %{
      sp_earned: pilot.sp_earned + sp_amount,
      sp_available: pilot.sp_available + sp_amount
    })
  end

  @doc """
  Allocate pilot SP to skill, edge tokens, or edge abilities
  """
  def allocate_pilot_sp(%Pilot{} = pilot, sp_amount, category) when category in [:skill, :edge_tokens, :edge_abilities] do
    updated_pilot = Pilot.allocate_sp(pilot, sp_amount, category)

    pilot
    |> Pilot.changeset(%{
      sp_allocated_to_skill: updated_pilot.sp_allocated_to_skill,
      sp_allocated_to_edge_tokens: updated_pilot.sp_allocated_to_edge_tokens,
      sp_allocated_to_edge_abilities: updated_pilot.sp_allocated_to_edge_abilities,
      sp_available: updated_pilot.sp_available,
      skill_level: updated_pilot.skill_level,
      edge_tokens: updated_pilot.edge_tokens
    })
    |> validate_sufficient_sp_for_allocation(pilot, sp_amount)
    |> Repo.update()
  end

  defp validate_sufficient_sp_for_allocation(changeset, %Pilot{sp_available: available}, sp_amount) do
    if available >= sp_amount do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :sp_available, "insufficient SP (need #{sp_amount}, have #{available})")
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking pilot changes
  """
  def change_pilot(%Pilot{} = pilot, attrs \\ %{}) do
    Pilot.changeset(pilot, attrs)
  end

end
