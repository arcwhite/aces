defmodule Aces.Companies.Pilots do
  @moduledoc """
  Pilot lifecycle and progression management for mercenary companies.
  """

  import Ecto.Query, warn: false
  alias Aces.Repo

  alias Aces.Companies.{Company, Pilot}
  alias Aces.Campaigns.PilotAllocation

  @hiring_cost 150

  @doc """
  Creates a pilot for a company.
  Also creates an initial PilotAllocation record to track the 150 SP allocation.
  """
  def create_pilot(%Company{} = company, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    pilot_changeset =
      %Pilot{}
      |> Pilot.changeset(Map.put(attrs, "company_id", company.id))
      |> validate_pilot_limit(company)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:pilot, pilot_changeset)
    |> Ecto.Multi.insert(:initial_allocation, fn %{pilot: pilot} ->
      build_initial_allocation_changeset(pilot)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{pilot: pilot}} -> {:ok, pilot}
      {:error, :pilot, changeset, _} -> {:error, changeset}
      {:error, :initial_allocation, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Creates multiple pilots for a company (used during company creation).
  Also creates initial PilotAllocation records for each pilot.
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
      |> Ecto.Multi.run(:pilots_and_allocations, fn _repo, _changes ->
        # Build multi that inserts each pilot and their initial allocation
        multi =
          pilots_attrs
          |> Enum.with_index()
          |> Enum.reduce(Ecto.Multi.new(), fn {attrs, index}, acc ->
            attrs = stringify_keys(attrs)
            pilot_changeset = Pilot.changeset(%Pilot{}, Map.put(attrs, "company_id", company.id))
            pilot_key = :"pilot_#{index}"
            allocation_key = :"allocation_#{index}"

            acc
            |> Ecto.Multi.insert(pilot_key, pilot_changeset)
            |> Ecto.Multi.insert(allocation_key, fn changes ->
              pilot = Map.get(changes, pilot_key)
              build_initial_allocation_changeset(pilot)
            end)
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
        {:ok, %{pilots_and_allocations: pilots}} -> {:ok, pilots}
        {:error, :pilots_and_allocations, error, _} -> {:error, error}
      end
    end
  end

  @doc """
  Updates a pilot.
  """
  def update_pilot(%Pilot{} = pilot, attrs) do
    pilot
    |> Pilot.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a pilot.
  """
  def delete_pilot(%Pilot{} = pilot) do
    Repo.delete(pilot)
  end

  @doc """
  Gets a pilot by ID.
  """
  def get_pilot!(id) do
    Repo.get!(Pilot, id)
  end

  @doc """
  Gets pilots for a company.
  """
  def list_company_pilots(%Company{id: company_id}) do
    from(p in Pilot,
      where: p.company_id == ^company_id,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  @doc """
  Gets active pilots for a company (deployable).
  """
  def list_active_company_pilots(%Company{id: company_id}) do
    from(p in Pilot,
      where: p.company_id == ^company_id and p.status == "active" and p.wounds < 3,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  @doc """
  Hire a new pilot for an active company (SP cost).
  Also creates an initial PilotAllocation record to track their 150 SP allocation.
  """
  def hire_pilot(%Company{} = company, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    changeset =
      %Pilot{}
      |> Pilot.changeset(Map.put(attrs, "company_id", company.id))
      |> validate_company_active_for_hiring(company)
      |> validate_sufficient_funds_for_hiring(company)

    if changeset.valid? do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:pilot, changeset)
      |> Ecto.Multi.insert(:initial_allocation, fn %{pilot: pilot} ->
        build_initial_allocation_changeset(pilot)
      end)
      |> Ecto.Multi.update(:company, Company.changeset(company, %{warchest_balance: company.warchest_balance - @hiring_cost}))
      |> Repo.transaction()
      |> case do
        {:ok, %{pilot: pilot, company: updated_company}} ->
          {:ok, pilot, updated_company}
        {:error, :pilot, changeset, _} ->
          {:error, changeset}
        {:error, :initial_allocation, changeset, _} ->
          {:error, changeset}
        {:error, :company, changeset, _} ->
          {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  @doc """
  Apply wounds to a pilot and update their status.
  """
  def wound_pilot(%Pilot{} = pilot, severity \\ 1) do
    wounded_pilot = Pilot.apply_wound(pilot, severity)
    update_pilot(pilot, %{wounds: wounded_pilot.wounds, status: wounded_pilot.status})
  end

  @doc """
  Award MVP bonus to a pilot (+20 SP).
  """
  def award_mvp(%Pilot{} = pilot) do
    update_pilot(pilot, %{
      sp_earned: pilot.sp_earned + 20,
      mvp_awards: pilot.mvp_awards + 1
    })
  end

  @doc """
  Award SP to a pilot.
  """
  def award_sp(%Pilot{} = pilot, sp_amount) when is_integer(sp_amount) and sp_amount > 0 do
    update_pilot(pilot, %{
      sp_earned: pilot.sp_earned + sp_amount,
      sp_available: pilot.sp_available + sp_amount
    })
  end

  @doc """
  Allocate pilot SP to skill, edge tokens, or edge abilities.
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

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking pilot changes.
  """
  def change_pilot(%Pilot{} = pilot, attrs \\ %{}) do
    Pilot.changeset(pilot, attrs)
  end

  ## Private Helpers

  defp validate_pilot_limit(changeset, %Company{status: "draft", pilots: pilots}) do
    if length(pilots || []) >= 6 do
      Ecto.Changeset.add_error(changeset, :base, "cannot add more than 6 pilots during company creation")
    else
      changeset
    end
  end

  defp validate_pilot_limit(changeset, _company), do: changeset

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

  defp validate_sufficient_sp_for_allocation(changeset, %Pilot{sp_available: available}, sp_amount) do
    if available >= sp_amount do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :sp_available, "insufficient SP (need #{sp_amount}, have #{available})")
    end
  end

  # Builds an initial PilotAllocation changeset from a newly created pilot's SP allocation
  defp build_initial_allocation_changeset(%Pilot{} = pilot) do
    sp_to_skill = pilot.sp_allocated_to_skill || 0
    sp_to_tokens = pilot.sp_allocated_to_edge_tokens || 0
    sp_to_abilities = pilot.sp_allocated_to_edge_abilities || 0
    total_sp = sp_to_skill + sp_to_tokens + sp_to_abilities

    PilotAllocation.initial_changeset(%PilotAllocation{}, %{
      pilot_id: pilot.id,
      sp_to_skill: sp_to_skill,
      sp_to_tokens: sp_to_tokens,
      sp_to_abilities: sp_to_abilities,
      edge_abilities_gained: pilot.edge_abilities || [],
      total_sp: total_sp
    })
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
