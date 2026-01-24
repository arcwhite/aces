defmodule Aces.CompaniesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Aces.Companies` context.
  """

  alias Aces.Companies
  alias Aces.Companies.Pilots
  alias Aces.AccountsFixtures

  def unique_company_name, do: "Company #{System.unique_integer()}"

  def valid_company_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_company_name(),
      description: "A test mercenary company",
      warchest_balance: 1000
    })
  end

  def company_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    user = Map.get(attrs, :user) || AccountsFixtures.user_fixture()
    status = Map.get(attrs, :status)
    attrs = Map.delete(attrs, :user)

    {:ok, company} =
      attrs
      |> valid_company_attributes()
      |> (&Companies.create_company(&1, user)).()

    # If a specific status was requested and it's not draft, update it directly
    if status && status != "draft" do
      {:ok, updated} = Companies.update_company(company, %{status: status})
      updated
    else
      company
    end
  end

  def company_with_members_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    owner = Map.get(attrs, :owner) || AccountsFixtures.user_fixture()
    editor = Map.get(attrs, :editor) || AccountsFixtures.user_fixture()
    viewer = Map.get(attrs, :viewer) || AccountsFixtures.user_fixture()

    company = company_fixture(Map.put(attrs, :user, owner))

    {:ok, _} = Companies.add_member(company, editor, "editor")
    {:ok, _} = Companies.add_member(company, viewer, "viewer")

    company = Companies.get_company!(company.id)
    %{company: company, owner: owner, editor: editor, viewer: viewer}
  end

  def valid_master_unit_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      mul_id: System.unique_integer([:positive]),
      name: "Atlas",
      variant: "AS7-D",
      unit_type: "battlemech",
      point_value: 48,
      tonnage: 100,
      last_synced_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
  end

  def master_unit_fixture(attrs \\ %{}) do
    {:ok, master_unit} =
      attrs
      |> valid_master_unit_attributes()
      |> (&Aces.Repo.insert(struct(Aces.Units.MasterUnit, &1))).()

    master_unit
  end

  def company_unit_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    company = Map.get(attrs, :company) || company_fixture()
    master_unit = Map.get(attrs, :master_unit) || master_unit_fixture()

    # Create the company unit directly without making HTTP calls
    {:ok, company_unit} =
      Aces.Repo.insert(%Aces.Companies.CompanyUnit{
        company_id: company.id,
        master_unit_id: master_unit.id,
        custom_name: Map.get(attrs, :custom_name),
        purchase_cost_sp: Map.get(attrs, :purchase_cost_sp, 1920)
      })

    # Reload to get the master_unit association
    Aces.Repo.preload(company_unit, [:master_unit, :company], force: true)
  end

  def unique_callsign, do: "Ace#{System.unique_integer([:positive])}"

  def valid_pilot_attributes(attrs \\ %{}) do
    # Default pilot with proper SP allocation for 2 edge tokens
    edge_tokens = Map.get(attrs, :edge_tokens, 2)
    sp_for_tokens = if edge_tokens > 1, do: 60, else: 0  # 2 tokens requires 60 SP

    Enum.into(attrs, %{
      name: "John Smith",
      callsign: unique_callsign(),
      skill_level: 4,
      edge_tokens: edge_tokens,
      status: "active",
      wounds: 0,
      sp_earned: 0,
      mvp_awards: 0,
      sp_allocated_to_skill: 0,
      sp_allocated_to_edge_tokens: sp_for_tokens,
      sp_allocated_to_edge_abilities: 0,
      sp_available: 150 - sp_for_tokens
    })
  end

  def pilot_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    company = Map.get(attrs, :company) || company_fixture()
    attrs = Map.delete(attrs, :company)

    {:ok, pilot} =
      attrs
      |> valid_pilot_attributes()
      |> (&Pilots.create_pilot(company, &1)).()

    pilot
  end

  def unique_campaign_name, do: "Campaign #{System.unique_integer()}"

  def valid_campaign_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      "name" => unique_campaign_name(),
      "description" => "A test campaign", 
      "difficulty_level" => "standard",
      "warchest_balance" => 5000
    })
  end

  def campaign_fixture(company, attrs \\ %{}) do
    {:ok, campaign} =
      attrs
      |> valid_campaign_attributes()
      |> (&Aces.Campaigns.create_campaign(company, &1)).()

    campaign
  end

  def unique_mission_number, do: "#{System.unique_integer([:positive])}"

  def valid_sortie_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      "mission_number" => unique_mission_number(),
      "name" => "Test Mission",
      "description" => "A test sortie",
      "pv_limit" => 200,
      "status" => "setup"
    })
  end

  def sortie_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    campaign = Map.get(attrs, :campaign)
    
    unless campaign do
      raise ArgumentError, "campaign is required for sortie fixture"
    end

    # Extract non-schema fields before creating params
    status = Map.get(attrs, :status, "setup")
    force_commander_id = Map.get(attrs, :force_commander_id)
    
    # Remove non-schema fields and prepare params with string keys only
    attrs_for_creation = 
      attrs
      |> Map.delete(:campaign)
      |> Map.delete(:status) 
      |> Map.delete(:force_commander_id)
      |> Enum.reduce(%{}, fn {k, v}, acc -> Map.put(acc, to_string(k), v) end)
    
    # Create the basic sortie
    {:ok, sortie} =
      attrs_for_creation
      |> (&Map.merge(valid_sortie_attributes(), &1)).()
      |> (&Aces.Campaigns.create_sortie(campaign, &1)).()

    # If status is in_progress, we need to start the sortie
    # But first we need at least one deployment with a named pilot
    if status == "in_progress" and force_commander_id do
      # Create a dummy deployment if needed
      if length(sortie.deployments) == 0 do
        # We need to create a minimal deployment to satisfy the requirement
        # This is not ideal but needed for testing
        raise ArgumentError, "Cannot create in_progress sortie without deployments. Create deployments separately."
      end
      
      {:ok, updated_sortie} = Aces.Campaigns.start_sortie(sortie, force_commander_id)
      updated_sortie
    else
      sortie
    end
  end

  def deployment_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    sortie = Map.get(attrs, :sortie)
    company_unit = Map.get(attrs, :company_unit) 
    pilot = Map.get(attrs, :pilot)
    
    unless sortie && company_unit do
      raise ArgumentError, "sortie and company_unit are required for deployment fixture"
    end

    deployment_attrs = %{
      company_unit_id: company_unit.id,
      pilot_id: pilot && pilot.id,
      configuration_changes: Map.get(attrs, :configuration_changes),
      configuration_cost_sp: Map.get(attrs, :configuration_cost_sp, 0)
    }

    {:ok, deployment} = Aces.Campaigns.create_deployment(sortie, deployment_attrs)
    
    # Reload with associations
    Aces.Repo.preload(deployment, [:pilot, company_unit: :master_unit])
  end
end
