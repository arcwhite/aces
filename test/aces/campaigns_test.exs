defmodule Aces.CampaignsTest do
  use Aces.DataCase

  alias Aces.Campaigns
  alias Aces.Campaigns.Sortie

  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures
  import Aces.UnitsFixtures

  describe "create_sortie/2" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      pilot = pilot_fixture(company: company)
      master_unit = units_master_unit_fixture()
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      %{
        user: user,
        company: company,
        campaign: campaign,
        pilot: pilot,
        master_unit: master_unit,
        company_unit: company_unit
      }
    end

    test "creates sortie with valid data", %{campaign: campaign} do
      sortie_attrs = %{
        "mission_number" => "1",
        "name" => "Test Mission",
        "description" => "A test mission",
        "pv_limit" => 200
      }

      assert {:ok, %Sortie{} = sortie} = Campaigns.create_sortie(campaign, sortie_attrs)
      assert sortie.mission_number == "1"
      assert sortie.name == "Test Mission"
      assert sortie.description == "A test mission"
      assert sortie.pv_limit == 200
      assert sortie.status == "setup"
      assert sortie.campaign_id == campaign.id
    end

    test "creates sortie with mission number containing letter", %{campaign: campaign} do
      sortie_attrs = %{
        "mission_number" => "2A",
        "name" => "Mission 2 Alpha",
        "pv_limit" => 300
      }

      assert {:ok, %Sortie{} = sortie} = Campaigns.create_sortie(campaign, sortie_attrs)
      assert sortie.mission_number == "2A"
      assert sortie.name == "Mission 2 Alpha"
      assert sortie.pv_limit == 300
    end

    test "validates required fields", %{campaign: campaign} do
      invalid_attrs = %{}

      assert {:error, %Ecto.Changeset{} = changeset} = Campaigns.create_sortie(campaign, invalid_attrs)
      assert errors_on(changeset) == %{
        mission_number: ["can't be blank"],
        name: ["can't be blank"],
        pv_limit: ["can't be blank"]
      }
    end

    test "validates mission number format", %{campaign: campaign} do
      invalid_attrs = %{
        "mission_number" => "invalid",
        "name" => "Test Mission",
        "pv_limit" => 200
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Campaigns.create_sortie(campaign, invalid_attrs)
      assert errors_on(changeset) == %{
        mission_number: ["must be a number, optionally followed by a letter (e.g., 1, 2A, 3B)"]
      }
    end

    test "validates pv_limit is positive", %{campaign: campaign} do
      invalid_attrs = %{
        "mission_number" => "1",
        "name" => "Test Mission", 
        "pv_limit" => -100
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Campaigns.create_sortie(campaign, invalid_attrs)
      assert errors_on(changeset) == %{
        pv_limit: ["must be greater than 0"]
      }
    end

    test "ensures unique mission number per campaign", %{campaign: campaign} do
      sortie_attrs = %{
        "mission_number" => "1",
        "name" => "First Mission",
        "pv_limit" => 200
      }

      # Create first sortie
      assert {:ok, _sortie} = Campaigns.create_sortie(campaign, sortie_attrs)

      # Try to create second sortie with same mission number
      duplicate_attrs = %{
        "mission_number" => "1",
        "name" => "Duplicate Mission",
        "pv_limit" => 300
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Campaigns.create_sortie(campaign, duplicate_attrs)
      assert %{campaign_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows same mission number in different campaigns", %{campaign: campaign1, company: company} do
      # Complete first campaign so we can create a second one  
      {:ok, _completed} = Campaigns.complete_campaign(campaign1, "completed")
      
      # Create second campaign for the same company
      campaign2 = campaign_fixture(company, %{"name" => "Campaign 2"})

      sortie_attrs = %{
        "mission_number" => "1",
        "name" => "Mission One",
        "pv_limit" => 200
      }

      # Create sortie in first campaign
      assert {:ok, _sortie1} = Campaigns.create_sortie(campaign1, sortie_attrs)

      # Create sortie with same mission number in second campaign
      assert {:ok, sortie2} = Campaigns.create_sortie(campaign2, sortie_attrs)
      assert sortie2.mission_number == "1"
      assert sortie2.campaign_id == campaign2.id
    end
  end

  describe "create_deployment/2" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      pilot = pilot_fixture(company: company)
      master_unit = units_master_unit_fixture()
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Test Mission",
        "pv_limit" => 200
      })

      %{
        sortie: sortie,
        pilot: pilot,
        company_unit: company_unit,
        company: company
      }
    end

    test "creates deployment with pilot", %{sortie: sortie, pilot: pilot, company_unit: company_unit} do
      deployment_attrs = %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      }

      assert {:ok, deployment} = Campaigns.create_deployment(sortie, deployment_attrs)
      assert deployment.company_unit_id == company_unit.id
      assert deployment.pilot_id == pilot.id
      assert deployment.sortie_id == sortie.id
    end

    test "creates deployment without pilot (unnamed crew)", %{sortie: sortie, company_unit: company_unit} do
      deployment_attrs = %{
        company_unit_id: company_unit.id,
        pilot_id: nil
      }

      assert {:ok, deployment} = Campaigns.create_deployment(sortie, deployment_attrs)
      assert deployment.company_unit_id == company_unit.id
      assert deployment.pilot_id == nil
      assert deployment.sortie_id == sortie.id
    end

    test "prevents duplicate unit deployment in same sortie", %{sortie: sortie, pilot: pilot, company_unit: company_unit} do
      deployment_attrs = %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      }

      # Create first deployment
      assert {:ok, _deployment} = Campaigns.create_deployment(sortie, deployment_attrs)

      # Get sortie with deployments to check validation
      sortie_with_deployments = Campaigns.get_sortie!(sortie.id)

      # Try to deploy same unit again
      assert {:error, :unit_already_deployed} = Campaigns.create_deployment(sortie_with_deployments, deployment_attrs)
    end

    test "prevents duplicate pilot deployment in same sortie", %{sortie: sortie, pilot: pilot, company_unit: company_unit, company: company} do
      # Create second unit
      master_unit2 = units_master_unit_fixture(%{name: "Unit 2"})
      company_unit2 = company_unit_fixture(company: company, master_unit: master_unit2)

      # Deploy pilot with first unit
      assert {:ok, _deployment1} = Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      })

      # Get sortie with deployments to check validation
      sortie_with_deployments = Campaigns.get_sortie!(sortie.id)

      # Try to deploy same pilot with second unit
      assert {:error, :pilot_already_deployed} = Campaigns.create_deployment(sortie_with_deployments, %{
        company_unit_id: company_unit2.id,
        pilot_id: pilot.id
      })
    end
  end

  describe "get_sortie!/1" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)

      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Test Mission",
        "pv_limit" => 200
      })

      %{sortie: sortie, campaign: campaign}
    end

    test "returns sortie with preloaded associations", %{sortie: sortie, campaign: campaign} do
      retrieved_sortie = Campaigns.get_sortie!(sortie.id)
      
      assert retrieved_sortie.id == sortie.id
      assert retrieved_sortie.campaign.id == campaign.id
      assert Ecto.assoc_loaded?(retrieved_sortie.campaign)
      assert Ecto.assoc_loaded?(retrieved_sortie.deployments)
    end
  end
end