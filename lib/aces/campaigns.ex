defmodule Aces.Campaigns do
  @moduledoc """
  The Campaigns context - business logic for campaign and sortie management
  """

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
          conflict_target: [:sortie_id, :pilot_id]
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
end