defmodule Aces.Campaigns do
  @moduledoc """
  The Campaigns context - business logic for campaign and sortie management
  """

  import Ecto.Query, warn: false
  alias Aces.Repo

  alias Aces.Companies.{Company, Pilot}
  alias Aces.Campaigns.{Campaign, Sortie, Deployment, CampaignEvent, PilotCampaignStats}

  ## Campaign CRUD

  @doc """
  Gets a campaign by ID with full associations
  """
  def get_campaign!(id) do
    Campaign
    |> preload([
      :company,
      sorties: [deployments: [:company_unit, :pilot]],
      campaign_events: [],
      pilot_campaign_stats: [:pilot]
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
      campaign_events: [],
      pilot_campaign_stats: [:pilot]
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
    |> Ecto.Multi.run(:pilot_stats, fn _repo, %{campaign: campaign} ->
      create_pilot_campaign_stats(company, campaign)
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
    Sortie
    |> preload([
      :campaign,
      :force_commander,
      :mvp_pilot,
      deployments: [company_unit: :master_unit, pilot: []]
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
    |> Ecto.Multi.run(:award_sp, fn _repo, %{calculate_expenses: final_sortie} ->
      award_pilot_sp(final_sortie)
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

  defp create_pilot_campaign_stats(%Company{pilots: pilots}, %Campaign{} = campaign) when is_list(pilots) do
    stats_data = 
      Enum.map(pilots, fn pilot ->
        %{
          pilot_id: pilot.id,
          campaign_id: campaign.id,
          inserted_at: DateTime.truncate(DateTime.utc_now(), :second),
          updated_at: DateTime.truncate(DateTime.utc_now(), :second)
        }
      end)
    
    {count, _} = Repo.insert_all(PilotCampaignStats, stats_data)
    {:ok, count}
  end

  defp create_pilot_campaign_stats(%Company{id: company_id}, %Campaign{} = campaign) do
    pilot_ids = Repo.all(from(p in Pilot, where: p.company_id == ^company_id, select: p.id))
    
    stats_data = 
      Enum.map(pilot_ids, fn pilot_id ->
        %{
          pilot_id: pilot_id,
          campaign_id: campaign.id,
          inserted_at: DateTime.truncate(DateTime.utc_now(), :second),
          updated_at: DateTime.truncate(DateTime.utc_now(), :second)
        }
      end)
    
    {count, _} = Repo.insert_all(PilotCampaignStats, stats_data)
    {:ok, count}
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

  defp award_pilot_sp(%Sortie{} = sortie) do
    participating_pilots = get_participating_pilots(sortie)
    non_participating_pilots = get_non_participating_pilots(sortie)
    
    sp_per_pilot = sortie.sp_per_participating_pilot
    sp_per_non_participant = div(sp_per_pilot, 2)
    
    # Award full SP to participating pilots
    Enum.each(participating_pilots, fn pilot ->
      Aces.Companies.award_sp(pilot, sp_per_pilot)
      update_pilot_campaign_stats(pilot, sortie.campaign_id, sp_per_pilot, true)
    end)
    
    # Award half SP to non-participating pilots
    Enum.each(non_participating_pilots, fn pilot ->
      Aces.Companies.award_sp(pilot, sp_per_non_participant)
      update_pilot_campaign_stats(pilot, sortie.campaign_id, sp_per_non_participant, false)
    end)
    
    # Award MVP bonus if specified
    if sortie.mvp_pilot_id do
      mvp_pilot = Repo.get!(Pilot, sortie.mvp_pilot_id)
      Aces.Companies.award_mvp(mvp_pilot)
      update_pilot_mvp_stats(mvp_pilot, sortie.campaign_id)
    end
    
    {:ok, :sp_awarded}
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

  defp update_pilot_campaign_stats(pilot, campaign_id, sp_earned, participated?) do
    stats = Repo.get_by(PilotCampaignStats, pilot_id: pilot.id, campaign_id: campaign_id)
    
    updated_stats = 
      if participated? do
        PilotCampaignStats.record_sortie_participation(stats, sp_earned)
      else
        %{stats | sp_earned: stats.sp_earned + sp_earned}
      end
    
    stats
    |> PilotCampaignStats.changeset(Map.from_struct(updated_stats))
    |> Repo.update()
  end

  defp update_pilot_mvp_stats(pilot, campaign_id) do
    stats = Repo.get_by(PilotCampaignStats, pilot_id: pilot.id, campaign_id: campaign_id)
    updated_stats = PilotCampaignStats.record_mvp_award(stats)
    
    stats
    |> PilotCampaignStats.changeset(Map.from_struct(updated_stats))
    |> Repo.update()
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
end