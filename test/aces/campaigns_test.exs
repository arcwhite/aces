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

    test "ensures unique mission number per campaign for active sorties", %{campaign: campaign} do
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
      assert %{campaign_id: ["already exists for an active sortie in this campaign"]} = errors_on(changeset)
    end

    test "allows retrying a failed sortie with the same mission number", %{campaign: campaign} do
      sortie_attrs = %{
        "mission_number" => "1",
        "name" => "First Attempt",
        "pv_limit" => 200
      }

      # Create first sortie
      assert {:ok, sortie} = Campaigns.create_sortie(campaign, sortie_attrs)

      # Directly mark the sortie as failed (simulating the workflow where a sortie
      # was started and then failed)
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{status: "failed"})
        |> Aces.Repo.update()

      # Now we should be able to create a new sortie with the same mission number
      retry_attrs = %{
        "mission_number" => "1",
        "name" => "Second Attempt",
        "pv_limit" => 200
      }

      assert {:ok, retry_sortie} = Campaigns.create_sortie(campaign, retry_attrs)
      assert retry_sortie.mission_number == "1"
      assert retry_sortie.name == "Second Attempt"
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
      assert {:error, %Ecto.Changeset{} = changeset} = Campaigns.create_deployment(sortie_with_deployments, deployment_attrs)
      assert %{company_unit_id: ["unit is already deployed in this sortie"]} = errors_on(changeset)
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
      assert {:error, %Ecto.Changeset{} = changeset} = Campaigns.create_deployment(sortie_with_deployments, %{
        company_unit_id: company_unit2.id,
        pilot_id: pilot.id
      })
      assert %{pilot_id: ["pilot is already deployed in this sortie"]} = errors_on(changeset)
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

  describe "calculate_pending_refit_cost/3" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      pilot = pilot_fixture(company: company)

      # Create OMNI unit and variants
      omni_unit = omni_mech_fixture(%{name: "Timber Wolf", variant: "Prime", point_value: 45, bf_size: 3})
      variant_a = omni_variant_fixture("Timber Wolf", %{variant: "A", point_value: 42})
      variant_b = omni_variant_fixture("Timber Wolf", %{variant: "B", point_value: 50})

      company_unit = company_unit_fixture(company: company, master_unit: omni_unit)

      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "OMNI Test",
        "pv_limit" => 200
      })

      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      })

      sortie = Campaigns.get_sortie!(sortie.id)
      deployment = hd(sortie.deployments)

      omni_variants = %{deployment.id => [omni_unit, variant_a, variant_b]}

      %{
        sortie: sortie,
        deployment: deployment,
        omni_unit: omni_unit,
        variant_a: variant_a,
        variant_b: variant_b,
        omni_variants: omni_variants
      }
    end

    test "returns 0 when no pending changes", %{sortie: sortie, omni_variants: omni_variants} do
      pending_changes = %{}
      assert Campaigns.calculate_pending_refit_cost(sortie, pending_changes, omni_variants) == 0
    end

    test "calculates size*5 cost for lower PV variant", %{
      sortie: sortie,
      deployment: deployment,
      variant_a: variant_a,
      omni_variants: omni_variants
    } do
      # variant_a has PV 42, which is less than Prime's 45
      pending_changes = %{deployment.id => variant_a.id}
      # Cost should be bf_size * 5 = 3 * 5 = 15
      assert Campaigns.calculate_pending_refit_cost(sortie, pending_changes, omni_variants) == 15
    end

    test "calculates size*40 cost for higher PV variant", %{
      sortie: sortie,
      deployment: deployment,
      variant_b: variant_b,
      omni_variants: omni_variants
    } do
      # variant_b has PV 50, which is more than Prime's 45
      pending_changes = %{deployment.id => variant_b.id}
      # Cost should be bf_size * 40 = 3 * 40 = 120
      assert Campaigns.calculate_pending_refit_cost(sortie, pending_changes, omni_variants) == 120
    end
  end

  describe "calculate_effective_deployed_pv/3" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      pilot = pilot_fixture(company: company)

      # Create OMNI unit and variants
      omni_unit = omni_mech_fixture(%{name: "Dire Wolf", variant: "Prime", point_value: 60, bf_size: 4})
      variant_a = omni_variant_fixture("Dire Wolf", %{variant: "A", point_value: 55})

      company_unit = company_unit_fixture(company: company, master_unit: omni_unit)

      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "PV Test",
        "pv_limit" => 200
      })

      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      })

      sortie = Campaigns.get_sortie!(sortie.id)
      deployment = hd(sortie.deployments)

      omni_variants = %{deployment.id => [omni_unit, variant_a]}

      %{
        sortie: sortie,
        deployment: deployment,
        omni_unit: omni_unit,
        variant_a: variant_a,
        omni_variants: omni_variants
      }
    end

    test "returns base PV when no pending changes", %{
      sortie: sortie,
      omni_unit: omni_unit,
      omni_variants: omni_variants
    } do
      pending_changes = %{}
      # Should return the original PV of 60
      assert Campaigns.calculate_effective_deployed_pv(sortie, pending_changes, omni_variants) == omni_unit.point_value
    end

    test "returns new variant PV when pending change exists", %{
      sortie: sortie,
      deployment: deployment,
      variant_a: variant_a,
      omni_variants: omni_variants
    } do
      pending_changes = %{deployment.id => variant_a.id}
      # Should return variant_a's PV of 55
      assert Campaigns.calculate_effective_deployed_pv(sortie, pending_changes, omni_variants) == variant_a.point_value
    end
  end

  describe "start_sortie_with_refits/5" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company, %{"warchest_balance" => 5000})
      pilot = pilot_fixture(company: company)

      # Create OMNI unit and variant
      omni_unit = omni_mech_fixture(%{name: "Summoner", variant: "Prime", point_value: 45, bf_size: 3})
      variant_a = omni_variant_fixture("Summoner", %{variant: "A", point_value: 42})

      company_unit = company_unit_fixture(company: company, master_unit: omni_unit)

      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Start Test",
        "pv_limit" => 100
      })

      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      })

      sortie = Campaigns.get_sortie!(sortie.id)
      deployment = hd(sortie.deployments)

      omni_variants = %{deployment.id => [omni_unit, variant_a]}

      %{
        sortie: sortie,
        deployment: deployment,
        campaign: campaign,
        company: company,
        pilot: pilot,
        omni_unit: omni_unit,
        variant_a: variant_a,
        omni_variants: omni_variants
      }
    end

    test "starts sortie without refits successfully", %{
      sortie: sortie,
      campaign: campaign,
      pilot: pilot,
      omni_variants: omni_variants
    } do
      pending_changes = %{}

      assert {:ok, updated_sortie, updated_campaign} =
               Campaigns.start_sortie_with_refits(sortie, pending_changes, omni_variants, pilot.id, campaign)

      assert updated_sortie.status == "in_progress"
      assert updated_sortie.force_commander_id == pilot.id
      # No refits, so warchest should be unchanged
      assert updated_campaign.warchest_balance == campaign.warchest_balance
    end

    test "starts sortie with refits and deducts cost", %{
      sortie: sortie,
      deployment: deployment,
      campaign: campaign,
      pilot: pilot,
      variant_a: variant_a,
      omni_variants: omni_variants
    } do
      pending_changes = %{deployment.id => variant_a.id}
      # Cost should be bf_size * 5 = 3 * 5 = 15 (lower PV variant)

      assert {:ok, updated_sortie, updated_campaign} =
               Campaigns.start_sortie_with_refits(sortie, pending_changes, omni_variants, pilot.id, campaign)

      assert updated_sortie.status == "in_progress"
      assert updated_campaign.warchest_balance == campaign.warchest_balance - 15
    end

    test "fails when force commander not deployed", %{
      sortie: sortie,
      campaign: campaign,
      company: company,
      omni_variants: omni_variants
    } do
      # Create a pilot that is NOT deployed
      other_pilot = pilot_fixture(company: company, name: "Other Pilot")

      assert {:error, message} =
               Campaigns.start_sortie_with_refits(sortie, %{}, omni_variants, other_pilot.id, campaign)

      assert message =~ "Force Commander must be one of the deployed pilots"
    end

    test "fails when insufficient warchest for refits", _ctx do
      # Create a separate company/campaign with very low warchest
      user = user_fixture()
      poor_company = company_fixture(user: user)
      {:ok, poor_campaign} =
        Campaigns.create_campaign(poor_company, %{
          "name" => "Poor Campaign",
          "warchest_balance" => 5
        })

      poor_pilot = pilot_fixture(company: poor_company)

      # Create sortie for the poor campaign
      {:ok, poor_sortie} =
        Campaigns.create_sortie(poor_campaign, %{
          "mission_number" => "1",
          "name" => "Poor Test",
          "pv_limit" => 100
        })

      # Create deployment
      omni_unit = omni_mech_fixture(%{name: "Hellbringer", variant: "Prime", point_value: 40, bf_size: 3})
      variant_high = omni_variant_fixture("Hellbringer", %{variant: "C", point_value: 50})

      company_unit = company_unit_fixture(company: poor_company, master_unit: omni_unit)

      {:ok, _dep} = Campaigns.create_deployment(poor_sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: poor_pilot.id
      })

      poor_sortie = Campaigns.get_sortie!(poor_sortie.id)
      poor_deployment = hd(poor_sortie.deployments)

      poor_omni_variants = %{poor_deployment.id => [omni_unit, variant_high]}
      pending_changes = %{poor_deployment.id => variant_high.id}

      # Higher PV variant costs size*40 = 3*40 = 120 SP

      assert {:error, message} =
               Campaigns.start_sortie_with_refits(poor_sortie, pending_changes, poor_omni_variants, poor_pilot.id, poor_campaign)

      assert message =~ "Insufficient warchest"
    end

    test "fails when PV exceeds limit after refits", %{
      sortie: sortie,
      deployment: deployment,
      campaign: campaign,
      pilot: pilot,
      omni_unit: _omni_unit,
      omni_variants: omni_variants
    } do
      # Create a high PV variant that would exceed the limit
      high_pv_variant = omni_variant_fixture("Summoner", %{variant: "X", point_value: 150})
      updated_variants = Map.update!(omni_variants, deployment.id, fn variants -> variants ++ [high_pv_variant] end)
      pending_changes = %{deployment.id => high_pv_variant.id}

      # Sortie PV limit is 100, variant has PV 150
      assert {:error, message} =
               Campaigns.start_sortie_with_refits(sortie, pending_changes, updated_variants, pilot.id, campaign)

      assert message =~ "Deployed PV"
      assert message =~ "exceeds sortie limit"
    end
  end
end