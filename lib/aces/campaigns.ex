defmodule Aces.Campaigns do
  @moduledoc """
  The Campaigns context - business logic for campaign and sortie management
  """

  # Dialyzer false positive: Ecto.Multi opaque type warnings when piping
  @dialyzer :no_opaque

  import Ecto.Query, warn: false
  alias Aces.Repo

  alias Aces.Companies.{Company, CompanyUnit, Pilot}
  alias Aces.Campaigns.{Campaign, Sortie, Deployment, CampaignEvent, PilotAllocation}
  alias Aces.Units.MasterUnit

  ## Campaign CRUD

  @doc """
  Gets a campaign by ID with full associations
  """
  def get_campaign!(id) do
    Campaign
    |> preload([
      :company,
      sorties: [deployments: [:company_unit, :pilot]],
      campaign_events: []
    ])
    |> Repo.get!(id)
  end

  @doc """
  Gets the active campaign for a company
  """
  def get_active_campaign(%Company{id: company_id}) do
    Campaign
    |> where(company_id: ^company_id, status: "active")
    |> preload([
      sorties: [deployments: [:company_unit, :pilot]],
      campaign_events: []
    ])
    |> Repo.one()
  end

  @doc """
  Lists all campaigns for given company IDs
  """
  def list_campaigns_by_company_ids(company_ids) when is_list(company_ids) do
    Campaign
    |> where([c], c.company_id in ^company_ids)
    |> preload([:company, :sorties])
    |> order_by([c], desc: c.updated_at)
    |> Repo.all()
  end

  @doc """
  Creates a campaign for a company
  """
  def create_campaign(%Company{} = company, attrs \\ %{}) do
    total_pilot_sp = calculate_total_pilot_sp(company)
    experience_modifier = calculate_experience_modifier(total_pilot_sp)

    attrs_with_company = 
      attrs
      |> Map.put("company_id", company.id)
      |> Map.put("experience_modifier", experience_modifier)
      |> Map.put_new("warchest_balance", company.warchest_balance)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:campaign, Campaign.creation_changeset(%Campaign{}, attrs_with_company))
    |> Ecto.Multi.insert(:start_event, fn %{campaign: campaign} ->
      CampaignEvent.creation_changeset(%CampaignEvent{}, %{
        campaign_id: campaign.id,
        event_type: "campaign_started",
        description: "Campaign started: #{campaign.name}"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{campaign: campaign}} ->
        {:ok, get_campaign!(campaign.id)}

      {:error, :campaign, changeset, _} ->
        {:error, changeset}

      {:error, _step, error, _} ->
        {:error, error}
    end
  end

  @doc """
  Updates a campaign
  """
  def update_campaign(%Campaign{} = campaign, attrs) do
    campaign
    |> Campaign.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Completes a campaign
  """
  def complete_campaign(%Campaign{} = campaign, outcome \\ "completed") do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:campaign, Campaign.completion_changeset(campaign, %{status: outcome}))
    |> Ecto.Multi.insert(:completion_event, fn %{campaign: updated_campaign} ->
      event_type = if outcome == "completed", do: "campaign_completed", else: "campaign_failed"
      description = if outcome == "completed", do: "Campaign completed successfully", else: "Campaign failed"
      
      CampaignEvent.creation_changeset(%CampaignEvent{}, %{
        campaign_id: updated_campaign.id,
        event_type: event_type,
        description: description
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{campaign: campaign}} -> {:ok, campaign}
      {:error, :campaign, changeset, _} -> {:error, changeset}
      {:error, _step, error, _} -> {:error, error}
    end
  end

  ## Sortie CRUD

  @doc """
  Gets a sortie by ID with full associations
  """
  def get_sortie!(id) do
    # Build a query for deployments ordered by PV (descending)
    deployments_query =
      from d in Deployment,
        join: cu in CompanyUnit, on: cu.id == d.company_unit_id,
        join: mu in MasterUnit, on: mu.id == cu.master_unit_id,
        order_by: [desc: mu.point_value],
        preload: [company_unit: {cu, master_unit: mu}, pilot: []]

    Sortie
    |> preload([
      :campaign,
      :force_commander,
      :mvp_pilot,
      deployments: ^deployments_query
    ])
    |> Repo.get!(id)
  end

  @doc """
  Creates a sortie for a campaign
  """
  def create_sortie(%Campaign{} = campaign, attrs \\ %{}) do
    attrs_with_campaign =
      attrs
      |> Map.put("campaign_id", campaign.id)

    %Sortie{}
    |> Sortie.creation_changeset(attrs_with_campaign)
    |> Repo.insert()
    |> case do
      {:ok, sortie} ->
        {:ok, get_sortie!(sortie.id)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates a sortie (only allowed when status is "setup")
  """
  def update_sortie(%Sortie{status: "setup"} = sortie, attrs) do
    sortie
    |> Sortie.creation_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, sortie} ->
        {:ok, get_sortie!(sortie.id)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_sortie(%Sortie{status: status}, _attrs) do
    {:error, "Cannot edit sortie that has already begun (status: #{status})"}
  end

  @doc """
  Starts a sortie (validates force commander and deployments via changeset)
  """
  def start_sortie(%Sortie{} = sortie, force_commander_id) do
    changeset = Sortie.start_changeset(sortie, %{force_commander_id: force_commander_id})

    if changeset.valid? do
      Ecto.Multi.new()
      |> Ecto.Multi.update(:sortie, changeset)
      |> Ecto.Multi.insert(:start_event, fn %{sortie: updated_sortie} ->
        CampaignEvent.creation_changeset(%CampaignEvent{}, %{
          campaign_id: updated_sortie.campaign_id,
          event_type: "sortie_started",
          description: "Started Sortie #{updated_sortie.mission_number}: #{updated_sortie.name}"
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{sortie: sortie}} -> {:ok, get_sortie!(sortie.id)}
        {:error, :sortie, changeset, _} -> {:error, changeset}
        {:error, _step, error, _} -> {:error, error}
      end
    else
      {:error, changeset}
    end
  end

  @doc """
  Completes a sortie with post-battle processing
  """
  def complete_sortie(%Sortie{} = sortie, completion_attrs, deployment_results \\ []) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:sortie, Sortie.completion_changeset(sortie, completion_attrs))
    |> Ecto.Multi.run(:update_deployments, fn _repo, %{sortie: updated_sortie} ->
      update_deployment_results(updated_sortie, deployment_results)
    end)
    |> Ecto.Multi.run(:calculate_expenses, fn _repo, %{sortie: updated_sortie, update_deployments: deployments} ->
      calculate_and_update_sortie_expenses(updated_sortie, deployments)
    end)
    |> Ecto.Multi.merge(fn %{calculate_expenses: final_sortie} ->
      build_pilot_awards_multi(final_sortie)
    end)
    |> Ecto.Multi.run(:record_events, fn _repo, %{calculate_expenses: final_sortie} ->
      record_sortie_completion_events(final_sortie)
    end)
    |> Ecto.Multi.update(:finalize, fn %{calculate_expenses: final_sortie} ->
      Sortie.finalize_changeset(final_sortie)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{finalize: sortie}} ->
        {:ok, get_sortie!(sortie.id)}

      {:error, :sortie, %Ecto.Changeset{} = changeset, _} ->
        {:error, changeset}

      {:error, :finalize, %Ecto.Changeset{} = changeset, _} ->
        {:error, changeset}

      {:error, _step, error, _} ->
        {:error, error}
    end
  end

  ## Deployment Management

  @doc """
  Creates a deployment for a sortie
  """
  def create_deployment(%Sortie{} = sortie, attrs) do
    attrs_with_sortie = Map.put(attrs, :sortie_id, sortie.id)

    %Deployment{}
    |> Deployment.creation_changeset(attrs_with_sortie)
    |> validate_unit_not_already_deployed(sortie)
    |> validate_pilot_not_already_deployed(sortie)
    |> Repo.insert()
  end

  @doc """
  Removes a deployment from a sortie
  """
  def remove_deployment(%Deployment{} = deployment) do
    Repo.delete(deployment)
  end

  @doc """
  Updates a deployment (e.g., to change pilot assignment)
  """
  def update_deployment(%Deployment{} = deployment, attrs) do
    deployment
    |> Deployment.creation_changeset(attrs)
    |> Repo.update()
  end

  ## Helper Functions

  defp validate_unit_not_already_deployed(changeset, %Sortie{deployments: deployments}) do
    company_unit_id = Ecto.Changeset.get_field(changeset, :company_unit_id)

    if Enum.any?(deployments, &(&1.company_unit_id == company_unit_id)) do
      Ecto.Changeset.add_error(changeset, :company_unit_id, "unit is already deployed in this sortie")
    else
      changeset
    end
  end

  defp validate_pilot_not_already_deployed(changeset, %Sortie{deployments: deployments}) do
    pilot_id = Ecto.Changeset.get_field(changeset, :pilot_id)

    if pilot_id && Enum.any?(deployments, &(&1.pilot_id == pilot_id)) do
      Ecto.Changeset.add_error(changeset, :pilot_id, "pilot is already deployed in this sortie")
    else
      changeset
    end
  end

  defp calculate_total_pilot_sp(%Company{pilots: pilots}) when is_list(pilots) do
    Enum.sum(Enum.map(pilots, & &1.sp_earned))
  end

  defp calculate_total_pilot_sp(%Company{id: company_id}) do
    Repo.aggregate(from(p in Pilot, where: p.company_id == ^company_id), :sum, :sp_earned) || 0
  end

  defp update_deployment_results(_sortie, []), do: {:ok, []}
  defp update_deployment_results(_sortie, deployment_results) do
    updated_deployments = 
      Enum.map(deployment_results, fn {deployment_id, result_attrs} ->
        deployment = Repo.get!(Deployment, deployment_id)
        {:ok, updated} = 
          deployment
          |> Deployment.post_battle_changeset(result_attrs)
          |> Repo.update()
        updated
      end)
    
    {:ok, updated_deployments}
  end

  defp calculate_and_update_sortie_expenses(sortie, deployments) do
    repair_costs = Enum.sum(Enum.map(deployments, & &1.repair_cost_sp))
    casualty_costs = Enum.sum(Enum.map(deployments, & &1.casualty_cost_sp))
    rearming_costs = Enum.sum(Enum.map(deployments, &Deployment.get_rearming_cost/1))
    
    total_expenses = (sortie.total_expenses || 0) + repair_costs + casualty_costs + rearming_costs
    net_earnings = (sortie.total_income || 0) - total_expenses

    updated_attrs = %{
      total_expenses: total_expenses,
      rearming_cost: rearming_costs,
      net_earnings: net_earnings
    }

    sortie
    |> Ecto.Changeset.change(updated_attrs)
    |> Repo.update()
  end

  @doc false
  # Builds an Ecto.Multi containing all pilot SP award operations.
  # This ensures all awards happen in a single transaction - if any fails, all roll back.
  defp build_pilot_awards_multi(%Sortie{} = sortie) do
    participating_pilots = get_participating_pilots(sortie)
    non_participating_pilots = get_non_participating_pilots(sortie)

    sp_per_pilot = sortie.sp_per_participating_pilot
    sp_per_non_participant = div(sp_per_pilot, 2)

    Ecto.Multi.new()
    |> add_pilot_sp_awards(participating_pilots, sp_per_pilot, sortie.campaign_id, true)
    |> add_pilot_sp_awards(non_participating_pilots, sp_per_non_participant, sortie.campaign_id, false)
    |> maybe_add_mvp_award(sortie)
  end

  defp add_pilot_sp_awards(multi, pilots, sp_amount, _campaign_id, _participated?) do
    Enum.reduce(pilots, multi, fn pilot, acc ->
      pilot_changeset = Pilot.changeset(pilot, %{
        sp_earned: pilot.sp_earned + sp_amount,
        sp_available: pilot.sp_available + sp_amount
      })

      Ecto.Multi.update(acc, {:award_sp, pilot.id}, pilot_changeset)
    end)
  end

  defp maybe_add_mvp_award(multi, %Sortie{mvp_pilot_id: nil}), do: multi
  defp maybe_add_mvp_award(multi, %Sortie{mvp_pilot_id: mvp_pilot_id}) do
    mvp_pilot = Repo.get!(Pilot, mvp_pilot_id)
    mvp_changeset = Pilot.changeset(mvp_pilot, %{
      sp_earned: mvp_pilot.sp_earned + 20,
      sp_available: mvp_pilot.sp_available + 20,
      mvp_awards: mvp_pilot.mvp_awards + 1
    })

    Ecto.Multi.update(multi, :award_mvp, mvp_changeset)
  end

  defp get_participating_pilots(%Sortie{deployments: deployments}) do
    deployments
    |> Enum.filter(& &1.pilot_id)
    |> Enum.map(& &1.pilot)
    |> Enum.uniq_by(& &1.id)
  end

  defp get_non_participating_pilots(%Sortie{campaign: %{company: company}} = sortie) do
    participating_pilot_ids = 
      sortie.deployments
      |> Enum.filter(& &1.pilot_id)
      |> Enum.map(& &1.pilot_id)
      |> Enum.uniq()
    
    company.pilots
    |> Enum.reject(&(&1.id in participating_pilot_ids))
  end

  defp record_sortie_completion_events(%Sortie{} = sortie) do
    event_type = if sortie.was_successful, do: "sortie_completed", else: "sortie_failed"

    %CampaignEvent{}
    |> CampaignEvent.creation_changeset(%{
      campaign_id: sortie.campaign_id,
      event_type: event_type,
      event_data: CampaignEvent.sortie_completed_data(sortie),
      description: CampaignEvent.generate_description(event_type, CampaignEvent.sortie_completed_data(sortie))
    })
    |> Repo.insert()
  end

  ## Campaign Business Logic

  @doc """
  Calculate experience modifier based on total pilot SP in the company.
  Higher SP companies get reduced experience gains to balance progression.
  """
  def calculate_experience_modifier(total_pilot_sp) do
    cond do
      total_pilot_sp <= 3000 -> 1.0
      total_pilot_sp <= 6000 -> 0.9
      total_pilot_sp <= 9000 -> 0.8
      total_pilot_sp <= 12000 -> 0.7
      true -> 0.6
    end
  end

  @doc """
  Get combined PV modifier (difficulty + experience) for a campaign.
  """
  def get_effective_pv_modifier(%Campaign{} = campaign, total_pilot_sp) do
    experience_modifier = calculate_experience_modifier(total_pilot_sp)
    campaign.pv_limit_modifier * experience_modifier
  end

  @doc """
  Add a keyword to a campaign. Returns updated campaign struct (not persisted).
  """
  def add_campaign_keyword(%Campaign{keywords: keywords} = campaign, new_keyword) when is_binary(new_keyword) do
    updated_keywords =
      keywords
      |> Kernel.++([new_keyword])
      |> Enum.uniq()

    %{campaign | keywords: updated_keywords}
  end

  ## Sortie Business Logic

  @doc """
  Check if a sortie can be started (has force commander and deployments with named pilot).
  """
  def sortie_can_start?(%Sortie{force_commander_id: nil}), do: false
  def sortie_can_start?(%Sortie{status: "setup", deployments: deployments}) when length(deployments) > 0 do
    Enum.any?(deployments, & &1.pilot_id != nil)
  end
  def sortie_can_start?(_), do: false

  @doc """
  Get deployments with participating pilots (exclude unnamed crew).
  """
  def participating_pilot_deployments(%Sortie{deployments: deployments}) do
    Enum.filter(deployments, & &1.pilot_id)
  end

  @doc """
  Calculate total PV deployed for a sortie.
  """
  def calculate_deployed_pv(%Sortie{deployments: deployments}) do
    deployments
    |> Enum.map(fn deployment ->
      if deployment.company_unit && deployment.company_unit.master_unit do
        deployment.company_unit.master_unit.point_value || 0
      else
        0
      end
    end)
    |> Enum.sum()
  end

  ## Pilot Allocation Management

  @doc """
  Gets all pilot allocations for a sortie.

  Returns a list of PilotAllocation records.
  """
  def get_sortie_pilot_allocations(sortie_id) do
    PilotAllocation
    |> where(sortie_id: ^sortie_id)
    |> Repo.all()
  end

  @doc """
  Gets all pilot allocations for a sortie, converted to saved format.

  Returns a map of pilot_id_string => saved_data, compatible with
  PilotAllocationState.build_all/2.
  """
  def get_sortie_pilot_allocations_as_saved_map(sortie_id) do
    allocations = get_sortie_pilot_allocations(sortie_id)

    if allocations == [] do
      %{}
    else
      # For sortie allocations, we need to also get each pilot's initial allocation
      # to compute baselines. The "saved" format expects baseline + add values.
      build_saved_map_from_allocations(allocations, sortie_id)
    end
  end

  defp build_saved_map_from_allocations(allocations, sortie_id) do
    # Get pilot IDs from sortie allocations
    pilot_ids = Enum.map(allocations, & &1.pilot_id)

    # Get all prior allocations for these pilots (everything before or including this sortie)
    # We need: initial allocation + all sortie allocations BEFORE this one to compute baseline
    prior_allocations = get_prior_allocations_for_pilots(pilot_ids, sortie_id)

    # Build the saved map for each pilot
    allocations
    |> Enum.map(fn alloc ->
      pilot_prior = Map.get(prior_allocations, alloc.pilot_id, [])

      # Baseline is sum of all allocations BEFORE this sortie
      baseline_skill = Enum.sum(Enum.map(pilot_prior, & &1.sp_to_skill))
      baseline_tokens = Enum.sum(Enum.map(pilot_prior, & &1.sp_to_tokens))
      baseline_abilities = Enum.sum(Enum.map(pilot_prior, & &1.sp_to_abilities))
      baseline_edge_abilities = Enum.flat_map(pilot_prior, & &1.edge_abilities_gained)

      saved = %{
        "baseline_skill" => baseline_skill,
        "baseline_tokens" => baseline_tokens,
        "baseline_abilities" => baseline_abilities,
        "baseline_edge_abilities" => baseline_edge_abilities,
        "add_skill" => alloc.sp_to_skill,
        "add_tokens" => alloc.sp_to_tokens,
        "add_abilities" => alloc.sp_to_abilities,
        "new_edge_abilities" => alloc.edge_abilities_gained,
        "sp_to_spend" => alloc.total_sp
      }

      {to_string(alloc.pilot_id), saved}
    end)
    |> Map.new()
  end

  defp get_prior_allocations_for_pilots(pilot_ids, sortie_id) do
    # Get the sortie to find its inserted_at timestamp
    sortie = Repo.get!(Sortie, sortie_id)

    # Get all allocations for these pilots that are:
    # 1. Initial allocations (sortie_id is nil), OR
    # 2. Sortie allocations from sorties created BEFORE this one
    PilotAllocation
    |> where([a], a.pilot_id in ^pilot_ids)
    |> where([a], is_nil(a.sortie_id) or a.sortie_id != ^sortie_id)
    |> join(:left, [a], s in Sortie, on: a.sortie_id == s.id)
    |> where([a, s], is_nil(a.sortie_id) or s.inserted_at < ^sortie.inserted_at)
    |> Repo.all()
    |> Enum.group_by(& &1.pilot_id)
  end

  @doc """
  Saves pilot allocations for a sortie.

  Takes a map of pilot_id => PilotAllocationState and creates/updates
  PilotAllocation records in the database.

  Returns {:ok, results} or {:error, reason}.
  """
  def save_sortie_pilot_allocations(sortie_id, allocations_map) do
    multi =
      Enum.reduce(allocations_map, Ecto.Multi.new(), fn {pilot_id, alloc_state}, multi ->
        attrs = %{
          pilot_id: pilot_id,
          sortie_id: sortie_id,
          allocation_type: "sortie",
          sp_to_skill: alloc_state.add_skill,
          sp_to_tokens: alloc_state.add_tokens,
          sp_to_abilities: alloc_state.add_abilities,
          edge_abilities_gained: alloc_state.new_edge_abilities,
          total_sp: alloc_state.sp_to_spend
        }

        changeset = PilotAllocation.sortie_changeset(%PilotAllocation{}, attrs)

        Ecto.Multi.insert(
          multi,
          {:pilot_allocation, pilot_id},
          changeset,
          on_conflict: {:replace, [:sp_to_skill, :sp_to_tokens, :sp_to_abilities, :edge_abilities_gained, :total_sp, :updated_at]},
          conflict_target: {:unsafe_fragment, "(sortie_id, pilot_id) WHERE sortie_id IS NOT NULL"}
        )
      end)

    Repo.transaction(multi)
  end

  @doc """
  Deletes all pilot allocations for a sortie.

  Used when reversing pilot allocations during cost changes.
  """
  def delete_sortie_pilot_allocations(sortie_id) do
    {deleted, _} =
      PilotAllocation
      |> where(sortie_id: ^sortie_id)
      |> Repo.delete_all()

    {:ok, deleted}
  end

  ## Pilot SP Distribution Functions

  @doc """
  Distribute SP to all pilots after a sortie is completed.

  This function:
  1. Uses SortieCompletion to calculate the SP distribution
  2. Updates the sortie with pilot_sp_cost, expenses, and net_earnings
  3. Updates each pilot's SP fields (sp_earned, sp_available, sorties_participated, mvp_awards)
  4. Applies casualty status updates (wounded/deceased) to pilots
  5. Uses Ecto.Multi for transaction safety

  Returns {:ok, updated_sortie} or {:error, reason}.

  ## Parameters
  - `sortie` - The sortie struct with preloaded deployments
  - `all_pilots` - List of all company pilots
  - `pilot_earnings` - Map from SortieCompletion.calculate_pilot_earnings/3
  - `mvp_id` - ID of the MVP pilot (or nil)
  """
  def distribute_pilot_sp(%Sortie{} = sortie, all_pilots, pilot_earnings, mvp_id) do
    alias Aces.Campaigns.SortieCompletion

    # Use business logic module to calculate distribution
    distribution = SortieCompletion.distribute_sp_to_pilots(all_pilots, pilot_earnings, mvp_id)

    # Recalculate expenses and net earnings including pilot SP cost
    new_total_expenses = (sortie.total_expenses || 0) + distribution.total_pilot_sp_cost
    new_net_earnings = (sortie.total_income || 0) - new_total_expenses

    # Build the multi transaction
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:sortie, fn _ ->
        sortie
        |> Ecto.Changeset.change(%{
          mvp_pilot_id: mvp_id,
          pilot_sp_cost: distribution.total_pilot_sp_cost,
          total_expenses: new_total_expenses,
          net_earnings: new_net_earnings,
          finalization_step: "spend_sp"
        })
      end)

    # Apply pilot changes
    multi =
      Enum.reduce(distribution.pilot_changes, multi, fn {pilot_id, changes}, acc ->
        pilot = Enum.find(all_pilots, &(&1.id == pilot_id))

        if pilot do
          Ecto.Multi.update(
            acc,
            {:pilot, pilot_id},
            Ecto.Changeset.change(pilot, changes)
          )
        else
          acc
        end
      end)

    # Apply casualty updates
    casualty_updates = SortieCompletion.build_casualty_updates(sortie.deployments)

    multi =
      Enum.reduce(casualty_updates, multi, fn {pilot_id, changes}, acc ->
        deployment = Enum.find(sortie.deployments, &(&1.pilot_id == pilot_id))

        if deployment && deployment.pilot do
          Ecto.Multi.update(
            acc,
            {:casualty, pilot_id},
            Ecto.Changeset.change(deployment.pilot, changes)
          )
        else
          acc
        end
      end)

    # Execute transaction
    case Repo.transaction(multi) do
      {:ok, %{sortie: updated_sortie}} ->
        {:ok, get_sortie!(updated_sortie.id)}

      {:error, _step, error, _changes} ->
        {:error, error}
    end
  end

  @doc """
  Revert pilot SP allocations from the spend_sp step.

  This function:
  1. Uses SortieCompletion to calculate reversal changes
  2. Deletes pilot allocations from the database
  3. Updates each pilot with reversed values
  4. Uses Ecto.Multi for transaction safety

  Returns {:ok, deleted_count} or {:error, reason}.

  ## Parameters
  - `sortie_id` - The sortie ID to revert allocations for
  - `all_pilots` - List of all company pilots
  """
  def revert_pilot_sp(sortie_id, all_pilots) do
    alias Aces.Campaigns.SortieCompletion

    # Calculate reversals using business logic module
    reversals = SortieCompletion.reverse_pilot_allocations(sortie_id, all_pilots)

    # Build the multi transaction
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:delete_allocations, fn _repo, _changes ->
        # delete_sortie_pilot_allocations returns {:ok, count}
        case delete_sortie_pilot_allocations(sortie_id) do
          {:ok, count} -> {:ok, count}
          error -> error
        end
      end)

    # Apply pilot reversals
    multi =
      Enum.reduce(reversals, multi, fn {pilot_id, changes}, acc ->
        pilot = Enum.find(all_pilots, &(&1.id == pilot_id))

        if pilot do
          Ecto.Multi.update(
            acc,
            {:pilot_reversal, pilot_id},
            Ecto.Changeset.change(pilot, changes)
          )
        else
          acc
        end
      end)

    # Execute transaction
    case Repo.transaction(multi) do
      {:ok, %{delete_allocations: deleted_count}} ->
        {:ok, deleted_count}

      {:error, _step, error, _changes} ->
        {:error, error}
    end
  end

  @doc """
  Handle MVP change after SP has already been distributed.

  This function:
  1. Reverts any pilot allocations from the spend_sp step
  2. Applies MVP changes to the old and new MVPs
  3. Updates the sortie with the new MVP and finalization step
  4. Uses Ecto.Multi for transaction safety

  Returns {:ok, updated_sortie} or {:error, reason}.

  ## Parameters
  - `sortie` - The sortie struct
  - `old_mvp_id` - ID of the previous MVP (or nil)
  - `new_mvp_id` - ID of the new MVP (or nil)
  - `all_pilots` - List of all company pilots
  """
  def handle_mvp_change(%Sortie{} = sortie, old_mvp_id, new_mvp_id, all_pilots) do
    alias Aces.Campaigns.SortieCompletion

    # Only process if MVP actually changed
    if old_mvp_id == new_mvp_id do
      # Just update finalization step
      sortie
      |> Ecto.Changeset.change(%{finalization_step: "spend_sp"})
      |> Repo.update()
    else
      # Calculate MVP changes using business logic module
      mvp_changes = SortieCompletion.calculate_mvp_change(old_mvp_id, new_mvp_id, all_pilots)

      # Build the multi transaction
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:revert_allocations, fn _repo, _changes ->
          revert_pilot_sp(sortie.id, all_pilots)
        end)

      # Apply old MVP changes
      multi =
        if mvp_changes.old_mvp_changes do
          old_mvp = Enum.find(all_pilots, &(&1.id == old_mvp_id))

          if old_mvp do
            Ecto.Multi.update(
              multi,
              :old_mvp,
              Ecto.Changeset.change(old_mvp, mvp_changes.old_mvp_changes)
            )
          else
            multi
          end
        else
          multi
        end

      # Apply new MVP changes
      multi =
        if mvp_changes.new_mvp_changes do
          new_mvp = Enum.find(all_pilots, &(&1.id == new_mvp_id))

          if new_mvp do
            Ecto.Multi.update(
              multi,
              :new_mvp,
              Ecto.Changeset.change(new_mvp, mvp_changes.new_mvp_changes)
            )
          else
            multi
          end
        else
          multi
        end

      # Update sortie with new MVP
      multi =
        Ecto.Multi.update(multi, :sortie, fn _ ->
          sortie
          |> Ecto.Changeset.change(%{
            mvp_pilot_id: new_mvp_id,
            finalization_step: "spend_sp"
          })
        end)

      # Execute transaction
      case Repo.transaction(multi) do
        {:ok, %{sortie: updated_sortie}} ->
          {:ok, get_sortie!(updated_sortie.id)}

        {:error, _step, error, _changes} ->
          {:error, error}
      end
    end
  end

  @doc """
  Calculate pilot performance stats for a campaign from actual sortie data.

  Returns a list of maps with pilot info and computed stats:
  - :pilot - the pilot struct
  - :sp_earned - total SP earned across all sorties in this campaign
  - :sorties_participated - number of sorties the pilot deployed in
  - :mvp_awards - number of times selected as MVP
  """
  def calculate_pilot_performance(%Campaign{} = campaign) do
    campaign_id = campaign.id

    # Get all completed sorties for this campaign
    completed_sortie_ids =
      Sortie
      |> where(campaign_id: ^campaign_id)
      |> where(status: "completed")
      |> select([s], s.id)
      |> Repo.all()

    # Get SP earned per pilot from pilot_allocations
    sp_by_pilot =
      PilotAllocation
      |> where([pa], pa.sortie_id in ^completed_sortie_ids)
      |> group_by([pa], pa.pilot_id)
      |> select([pa], {pa.pilot_id, sum(pa.total_sp)})
      |> Repo.all()
      |> Map.new()

    # Get sortie participation counts from deployments
    participation_by_pilot =
      Deployment
      |> join(:inner, [d], s in Sortie, on: d.sortie_id == s.id)
      |> where([d, s], s.id in ^completed_sortie_ids)
      |> where([d, s], not is_nil(d.pilot_id))
      |> group_by([d, s], d.pilot_id)
      |> select([d, s], {d.pilot_id, count(d.id)})
      |> Repo.all()
      |> Map.new()

    # Get MVP awards per pilot
    mvp_by_pilot =
      Sortie
      |> where([s], s.id in ^completed_sortie_ids)
      |> where([s], not is_nil(s.mvp_pilot_id))
      |> group_by([s], s.mvp_pilot_id)
      |> select([s], {s.mvp_pilot_id, count(s.id)})
      |> Repo.all()
      |> Map.new()

    # Get all pilots who have any stats
    all_pilot_ids =
      MapSet.new(Map.keys(sp_by_pilot))
      |> MapSet.union(MapSet.new(Map.keys(participation_by_pilot)))
      |> MapSet.union(MapSet.new(Map.keys(mvp_by_pilot)))
      |> MapSet.to_list()

    # Fetch pilot records
    pilots =
      Pilot
      |> where([p], p.id in ^all_pilot_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    # Build result list sorted by SP earned (descending)
    all_pilot_ids
    |> Enum.map(fn pilot_id ->
      %{
        pilot: Map.get(pilots, pilot_id),
        sp_earned: Map.get(sp_by_pilot, pilot_id, 0),
        sorties_participated: Map.get(participation_by_pilot, pilot_id, 0),
        mvp_awards: Map.get(mvp_by_pilot, pilot_id, 0)
      }
    end)
    |> Enum.filter(& &1.pilot)  # Filter out any pilots that might have been deleted
    |> Enum.sort_by(& &1.sp_earned, :desc)
  end

  ## OMNI Variant Reconfiguration

  @doc """
  Change an OMNI unit's variant during sortie setup.

  This function:
  1. Validates the new variant is a valid chassis variant
  2. Calculates the refit cost (size * 5 SP if new PV <= old PV, size * 40 SP if new PV > old PV)
  3. Checks if campaign has enough warchest balance
  4. Updates the company_unit to point to the new master_unit
  5. Records the configuration change and cost on the deployment
  6. Deducts the cost from the campaign warchest

  Returns {:ok, deployment} or {:error, reason}.
  """
  def change_omni_variant(%Deployment{} = deployment, new_master_unit_id, %Campaign{} = campaign) do
    require Logger
    Logger.info("change_omni_variant called - deployment: #{deployment.id}, new_master_unit_id: #{new_master_unit_id}, campaign: #{campaign.id}")

    deployment = Repo.preload(deployment, company_unit: :master_unit)
    current_unit = deployment.company_unit.master_unit
    new_unit = Repo.get!(MasterUnit, new_master_unit_id)

    Logger.info("Current unit: #{current_unit.name} #{current_unit.variant} (id: #{current_unit.id})")
    Logger.info("New unit: #{new_unit.name} #{new_unit.variant} (id: #{new_unit.id})")

    # Validate units have same chassis name (both are variants of the same OMNI)
    unless current_unit.name == new_unit.name do
      {:error, "New variant must be the same chassis as the current unit"}
    else
      # Calculate refit cost
      unit_size = current_unit.bf_size || 1
      current_pv = current_unit.point_value || 0
      new_pv = new_unit.point_value || 0

      refit_cost =
        if new_pv <= current_pv do
          unit_size * 5
        else
          unit_size * 40
        end

      # Check warchest balance
      if campaign.warchest_balance < refit_cost do
        {:error, "Insufficient warchest balance. Need #{refit_cost} SP, have #{campaign.warchest_balance} SP"}
      else
        # Perform the update in a transaction
        Ecto.Multi.new()
        |> Ecto.Multi.update(:company_unit, fn _ ->
          deployment.company_unit
          |> Ecto.Changeset.change(%{master_unit_id: new_master_unit_id})
        end)
        |> Ecto.Multi.update(:deployment, fn _ ->
          config_note = "Refitted from #{current_unit.variant} to #{new_unit.variant}"
          new_config_cost = (deployment.configuration_cost_sp || 0) + refit_cost

          deployment
          |> Deployment.changeset(%{
            configuration_changes: config_note,
            configuration_cost_sp: new_config_cost
          })
        end)
        |> Ecto.Multi.update(:campaign, fn _ ->
          new_balance = campaign.warchest_balance - refit_cost

          campaign
          |> Campaign.changeset(%{warchest_balance: new_balance})
        end)
        |> Ecto.Multi.insert(:event, fn _ ->
          CampaignEvent.creation_changeset(%CampaignEvent{}, %{
            campaign_id: campaign.id,
            event_type: "unit_refitted",
            description: "#{deployment.company_unit.custom_name || current_unit.name} refitted to #{new_unit.variant} variant (-#{refit_cost} SP)"
          })
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{deployment: updated_deployment}} ->
            {:ok, Repo.preload(updated_deployment, [company_unit: :master_unit], force: true)}

          {:error, _step, error, _} ->
            {:error, error}
        end
      end
    end
  end

  @doc """
  Calculate the cost of changing to a different OMNI variant.

  Returns the SP cost: size * 5 if new PV <= old PV, size * 40 if new PV > old PV.
  """
  def calculate_omni_refit_cost(current_master_unit, new_master_unit) do
    unit_size = current_master_unit.bf_size || 1
    current_pv = current_master_unit.point_value || 0
    new_pv = new_master_unit.point_value || 0

    if new_pv <= current_pv do
      unit_size * 5
    else
      unit_size * 40
    end
  end

  @doc """
  Calculate the total SP cost for all pending OMNI variant changes.

  Takes a sortie with deployments, a map of deployment_id => new_variant_id,
  and a map of deployment_id => [available variants].

  Returns the total SP cost as an integer.
  """
  def calculate_pending_refit_cost(%Sortie{} = sortie, pending_changes, omni_variants)
      when is_map(pending_changes) and is_map(omni_variants) do
    Enum.reduce(pending_changes, 0, fn {deployment_id, new_variant_id}, total ->
      deployment = Enum.find(sortie.deployments, &(&1.id == deployment_id))

      if deployment do
        variants = Map.get(omni_variants, deployment_id, [])
        current_unit = deployment.company_unit.master_unit
        new_unit = Enum.find(variants, &(&1.id == new_variant_id))

        if new_unit do
          total + calculate_omni_refit_cost(current_unit, new_unit)
        else
          total
        end
      else
        total
      end
    end)
  end

  @doc """
  Calculate effective deployed PV considering pending OMNI variant changes.

  Takes a sortie with deployments, a map of deployment_id => new_variant_id,
  and a map of deployment_id => [available variants].

  Returns the total PV as an integer, using pending variant PVs where applicable.
  """
  def calculate_effective_deployed_pv(%Sortie{} = sortie, pending_changes, omni_variants)
      when is_map(pending_changes) and is_map(omni_variants) do
    Enum.reduce(sortie.deployments, 0, fn deployment, total ->
      base_pv = deployment.company_unit.master_unit.point_value || 0

      case Map.get(pending_changes, deployment.id) do
        nil ->
          total + base_pv

        new_variant_id ->
          variants = Map.get(omni_variants, deployment.id, [])
          new_variant = Enum.find(variants, &(&1.id == new_variant_id))

          if new_variant do
            total + (new_variant.point_value || 0)
          else
            total + base_pv
          end
      end
    end)
  end

  @doc """
  Starts a sortie with OMNI refits, performing all validations and updates atomically.

  This function:
  1. Validates no other sortie is in progress for the campaign
  2. Validates the force commander is deployed
  3. Validates sufficient warchest for OMNI refits
  4. Validates effective PV is within the sortie limit
  5. Commits all pending variant changes
  6. Starts the sortie

  Returns {:ok, updated_sortie, updated_campaign} or {:error, message}.
  """
  def start_sortie_with_refits(
        %Sortie{} = sortie,
        pending_changes,
        omni_variants,
        force_commander_id,
        %Campaign{id: campaign_id}
      )
      when is_map(pending_changes) and is_map(omni_variants) do
    # Re-fetch campaign to ensure we have fresh data for validations
    campaign = get_campaign!(campaign_id)

    with :ok <- validate_no_in_progress_sorties(campaign, sortie.id),
         :ok <- validate_force_commander_deployed(sortie, force_commander_id),
         :ok <- validate_warchest_for_refits(sortie, pending_changes, omni_variants, campaign),
         :ok <- validate_pv_within_limit(sortie, pending_changes, omni_variants) do
      # Commit variant changes first (if any)
      case commit_variant_changes_if_any(sortie, pending_changes, omni_variants, campaign) do
        {:ok, updated_campaign} ->
          # Now start the sortie
          case start_sortie(sortie, force_commander_id) do
            {:ok, updated_sortie} ->
              {:ok, updated_sortie, updated_campaign}

            {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
              {:error, format_changeset_errors(changeset)}

            {:error, message} ->
              {:error, message}
          end

        {:error, message} ->
          {:error, message}
      end
    end
  end

  # Validation helpers for start_sortie_with_refits

  defp validate_no_in_progress_sorties(%Campaign{sorties: sorties}, current_sortie_id) do
    in_progress_sorties = Enum.filter(sorties, fn s ->
      s.status == "in_progress" and s.id != current_sortie_id
    end)

    if length(in_progress_sorties) > 0 do
      {:error, "Only one sortie can be in progress at a time. Complete the current sortie before starting a new one."}
    else
      :ok
    end
  end

  defp validate_force_commander_deployed(%Sortie{} = sortie, force_commander_id) do
    deployed_pilot_ids =
      sortie.deployments
      |> Enum.filter(& &1.pilot_id)
      |> Enum.map(& &1.pilot_id)

    if force_commander_id in deployed_pilot_ids do
      :ok
    else
      {:error, "Force Commander must be one of the deployed pilots"}
    end
  end

  defp validate_warchest_for_refits(sortie, pending_changes, omni_variants, campaign) do
    total_cost = calculate_pending_refit_cost(sortie, pending_changes, omni_variants)

    if total_cost > campaign.warchest_balance do
      {:error, "Insufficient warchest for OMNI refits. Need #{total_cost} SP, have #{campaign.warchest_balance} SP."}
    else
      :ok
    end
  end

  defp validate_pv_within_limit(sortie, pending_changes, omni_variants) do
    effective_pv = calculate_effective_deployed_pv(sortie, pending_changes, omni_variants)

    if effective_pv > sortie.pv_limit do
      {:error, "Deployed PV (#{effective_pv}) exceeds sortie limit (#{sortie.pv_limit}). Adjust OMNI variants to reduce PV."}
    else
      :ok
    end
  end

  defp commit_variant_changes_if_any(_sortie, pending_changes, _omni_variants, campaign)
       when map_size(pending_changes) == 0 do
    {:ok, campaign}
  end

  defp commit_variant_changes_if_any(sortie, pending_changes, omni_variants, campaign) do
    commit_omni_refits(sortie, pending_changes, omni_variants, campaign)
  end

  defp format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
    |> Enum.join(", ")
  end

  @doc """
  Commits all pending OMNI variant changes when starting a sortie.

  This function:
  1. Calculates the total refit cost for all pending changes
  2. Updates each company_unit to point to the new master_unit
  3. Records configuration changes and costs on each deployment
  4. Deducts the total cost from the campaign warchest
  5. Creates campaign events for each refit

  Returns {:ok, updated_campaign} or {:error, reason}.
  """
  def commit_omni_refits(sortie, pending_changes, omni_variants, campaign) do
    # Build list of changes with their costs
    changes_with_costs =
      Enum.map(pending_changes, fn {deployment_id, new_variant_id} ->
        deployment = Enum.find(sortie.deployments, &(&1.id == deployment_id))
        variants = Map.get(omni_variants, deployment_id, [])
        current_unit = deployment.company_unit.master_unit
        new_unit = Enum.find(variants, &(&1.id == new_variant_id))

        cost = calculate_omni_refit_cost(current_unit, new_unit)

        %{
          deployment: deployment,
          current_unit: current_unit,
          new_unit: new_unit,
          cost: cost
        }
      end)

    total_cost = Enum.sum(Enum.map(changes_with_costs, & &1.cost))

    # Build the multi transaction
    multi =
      changes_with_costs
      |> Enum.with_index()
      |> Enum.reduce(Ecto.Multi.new(), fn {change, idx}, multi ->
        multi
        |> Ecto.Multi.update(
          {:company_unit, idx},
          Ecto.Changeset.change(change.deployment.company_unit, %{
            master_unit_id: change.new_unit.id
          })
        )
        |> Ecto.Multi.update(
          {:deployment, idx},
          Deployment.changeset(change.deployment, %{
            configuration_changes: "Refitted from #{change.current_unit.variant} to #{change.new_unit.variant}",
            configuration_cost_sp: change.cost
          })
        )
        |> Ecto.Multi.insert(
          {:event, idx},
          CampaignEvent.creation_changeset(%CampaignEvent{}, %{
            campaign_id: campaign.id,
            event_type: "unit_refitted",
            description: "#{change.deployment.company_unit.custom_name || change.current_unit.name} refitted to #{change.new_unit.variant} variant (-#{change.cost} SP)"
          })
        )
      end)

    # Add the warchest deduction
    multi =
      Ecto.Multi.update(multi, :campaign, fn _ ->
        Campaign.changeset(campaign, %{warchest_balance: campaign.warchest_balance - total_cost})
      end)

    # Execute transaction
    case Repo.transaction(multi) do
      {:ok, %{campaign: updated_campaign}} ->
        {:ok, get_campaign!(updated_campaign.id)}

      {:error, _step, error, _changes} ->
        {:error, "Failed to commit variant changes: #{inspect(error)}"}
    end
  end
end