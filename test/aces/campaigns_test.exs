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

  describe "distribute_pilot_sp/4" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company, %{"warchest_balance" => 5000})

      # Create pilots with valid SP allocations
      # Validation: sp_allocated_to_skill + sp_allocated_to_edge_tokens + sp_allocated_to_edge_abilities + sp_available == 150 + sp_earned
      # Default fixture has 60 SP allocated to edge tokens (2 tokens)
      # pilot1: 100 + 60 + 0 + 50 = 210 = 150 + 60
      pilot1 = pilot_fixture(company: company, name: "Pilot 1", sp_earned: 60, sp_available: 50, sp_allocated_to_skill: 100)
      # pilot2: 50 + 60 + 0 + 100 = 210 = 150 + 60
      pilot2 = pilot_fixture(company: company, name: "Pilot 2", sp_earned: 60, sp_available: 100, sp_allocated_to_skill: 50)
      # pilot3: 0 + 60 + 0 + 200 = 260 = 150 + 110
      pilot3 = pilot_fixture(company: company, name: "Pilot 3", sp_earned: 110, sp_available: 200, sp_allocated_to_skill: 0)

      # Create sortie
      master_unit = units_master_unit_fixture()
      company_unit1 = company_unit_fixture(company: company, master_unit: master_unit)
      company_unit2 = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "SP Distribution Test",
        "pv_limit" => 200
      })

      # Set sp_per_participating_pilot (normally set during completion wizard)
      {:ok, sortie} =
        sortie
        |> Ecto.Changeset.change(%{sp_per_participating_pilot: 100})
        |> Aces.Repo.update()

      # Deploy pilot1 and pilot2, pilot3 stays home
      {:ok, _} = Campaigns.create_deployment(sortie, %{company_unit_id: company_unit1.id, pilot_id: pilot1.id})
      {:ok, _} = Campaigns.create_deployment(sortie, %{company_unit_id: company_unit2.id, pilot_id: pilot2.id})

      # Reload sortie with deployments before starting
      sortie = Campaigns.get_sortie!(sortie.id)

      # Start and set income/expenses to simulate post-costs state
      {:ok, sortie} = Campaigns.start_sortie(sortie, pilot1.id)

      sortie = Campaigns.get_sortie!(sortie.id)
      {:ok, sortie} =
        sortie
        |> Ecto.Changeset.change(%{
          total_income: 500,
          total_expenses: 100,
          net_earnings: 400,
          finalization_step: "pilots"
        })
        |> Aces.Repo.update()

      sortie = Campaigns.get_sortie!(sortie.id)

      all_pilots = [pilot1, pilot2, pilot3]

      # Calculate pilot earnings
      participating_pilot_ids = MapSet.new([pilot1.id, pilot2.id])
      pilot_earnings = Aces.Campaigns.SortieCompletion.calculate_pilot_earnings(
        sortie,
        all_pilots,
        participating_pilot_ids,
        net_earnings: 400
      )

      %{
        sortie: sortie,
        campaign: campaign,
        pilot1: pilot1,
        pilot2: pilot2,
        pilot3: pilot3,
        all_pilots: all_pilots,
        pilot_earnings: pilot_earnings
      }
    end

    test "distributes SP to pilots and updates sortie", %{
      sortie: sortie,
      all_pilots: all_pilots,
      pilot_earnings: pilot_earnings,
      pilot1: pilot1
    } do
      assert {:ok, updated_sortie} = Campaigns.distribute_pilot_sp(sortie, all_pilots, pilot_earnings, pilot1.id)

      # Check sortie was updated
      assert updated_sortie.mvp_pilot_id == pilot1.id
      assert updated_sortie.pilot_sp_cost > 0
      assert updated_sortie.finalization_step == "spend_sp"

      # Total expenses should include pilot SP cost
      assert updated_sortie.total_expenses == sortie.total_expenses + updated_sortie.pilot_sp_cost

      # Net earnings should be recalculated
      assert updated_sortie.net_earnings == updated_sortie.total_income - updated_sortie.total_expenses
    end

    test "updates pilot SP fields correctly", %{
      sortie: sortie,
      all_pilots: all_pilots,
      pilot_earnings: pilot_earnings,
      pilot1: pilot1,
      pilot2: pilot2,
      pilot3: pilot3
    } do
      assert {:ok, _updated_sortie} = Campaigns.distribute_pilot_sp(sortie, all_pilots, pilot_earnings, pilot1.id)

      # Reload pilots
      pilot1_updated = Aces.Repo.get!(Aces.Companies.Pilot, pilot1.id)
      _pilot2_updated = Aces.Repo.get!(Aces.Companies.Pilot, pilot2.id)
      pilot3_updated = Aces.Repo.get!(Aces.Companies.Pilot, pilot3.id)

      # Participating pilots should get SP
      assert pilot1_updated.sp_earned > pilot1.sp_earned
      assert pilot1_updated.sp_available > 0
      assert pilot1_updated.sorties_participated == (pilot1.sorties_participated || 0) + 1

      # MVP should get bonus
      assert pilot1_updated.mvp_awards == (pilot1.mvp_awards || 0) + 1

      # Non-participating pilot should get half share
      assert pilot3_updated.sp_earned > pilot3.sp_earned
      assert pilot3_updated.sp_available > 0
      assert pilot3_updated.sorties_participated == (pilot3.sorties_participated || 0)
    end

    test "handles nil MVP correctly", %{
      sortie: sortie,
      all_pilots: all_pilots,
      pilot_earnings: pilot_earnings
    } do
      assert {:ok, updated_sortie} = Campaigns.distribute_pilot_sp(sortie, all_pilots, pilot_earnings, nil)

      assert updated_sortie.mvp_pilot_id == nil
      assert updated_sortie.finalization_step == "spend_sp"
    end
  end

  describe "revert_pilot_sp/2" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)

      # Validation: sp_allocated_to_skill + sp_allocated_to_edge_tokens + sp_allocated_to_edge_abilities + sp_available == 150 + sp_earned
      # 100 + 60 (default for 2 tokens) + 0 + 50 = 210 = 150 + 60
      pilot1 = pilot_fixture(company: company, name: "Pilot 1",
        sp_earned: 60,
        sp_allocated_to_skill: 100,
        skill_level: 4,
        sp_available: 50
      )

      master_unit = units_master_unit_fixture()
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Reversal Test",
        "pv_limit" => 200
      })

      {:ok, _} = Campaigns.create_deployment(sortie, %{company_unit_id: company_unit.id, pilot_id: pilot1.id})

      # Reload sortie with deployments before starting
      sortie = Campaigns.get_sortie!(sortie.id)
      {:ok, sortie} = Campaigns.start_sortie(sortie, pilot1.id)

      # Create a pilot allocation to reverse
      allocation_attrs = %{
        pilot1.id => %{
          pilot: pilot1,
          baseline_skill: 100,
          baseline_tokens: 0,
          baseline_abilities: 0,
          baseline_edge_abilities: [],
          add_skill: 50,
          add_tokens: 0,
          add_abilities: 0,
          new_edge_abilities: [],
          sp_to_spend: 50
        }
      }

      {:ok, _} = Campaigns.save_sortie_pilot_allocations(sortie.id, allocation_attrs)

      %{sortie: sortie, pilot1: pilot1, all_pilots: [pilot1]}
    end

    test "reverts pilot allocations and deletes allocation records", %{
      sortie: sortie,
      pilot1: pilot1,
      all_pilots: all_pilots
    } do
      # Verify allocation exists
      allocations_before = Campaigns.get_sortie_pilot_allocations(sortie.id)
      assert length(allocations_before) == 1

      assert {:ok, deleted_count} = Campaigns.revert_pilot_sp(sortie.id, all_pilots)

      # Check that allocation was deleted
      assert deleted_count == 1
      allocations_after = Campaigns.get_sortie_pilot_allocations(sortie.id)
      assert length(allocations_after) == 0

      # Reload pilot and verify reversal
      pilot1_updated = Aces.Repo.get!(Aces.Companies.Pilot, pilot1.id)

      # Should revert to baseline
      assert pilot1_updated.sp_allocated_to_skill == 100
      assert pilot1_updated.sp_available == 50
    end

    test "handles empty allocations gracefully", %{all_pilots: all_pilots} do
      # Use a sortie ID that has no allocations
      assert {:ok, 0} = Campaigns.revert_pilot_sp(99999, all_pilots)
    end
  end

  describe "handle_mvp_change/4" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)

      # Validation: sp_allocated_to_skill + sp_allocated_to_edge_tokens + sp_allocated_to_edge_abilities + sp_available == 150 + sp_earned
      # pilot1: 100 + 60 (default) + 0 + 50 = 210 = 150 + 60
      # pilot2: 50 + 60 (default) + 0 + 100 = 210 = 150 + 60
      pilot1 = pilot_fixture(company: company, name: "Pilot 1", sp_earned: 60, sp_available: 50, sp_allocated_to_skill: 100, mvp_awards: 1)
      pilot2 = pilot_fixture(company: company, name: "Pilot 2", sp_earned: 60, sp_available: 100, sp_allocated_to_skill: 50, mvp_awards: 0)

      master_unit = units_master_unit_fixture()
      company_unit1 = company_unit_fixture(company: company, master_unit: master_unit)
      company_unit2 = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "MVP Change Test",
        "pv_limit" => 200
      })

      {:ok, _} = Campaigns.create_deployment(sortie, %{company_unit_id: company_unit1.id, pilot_id: pilot1.id})
      {:ok, _} = Campaigns.create_deployment(sortie, %{company_unit_id: company_unit2.id, pilot_id: pilot2.id})

      # Reload sortie with deployments before starting
      sortie = Campaigns.get_sortie!(sortie.id)
      {:ok, sortie} = Campaigns.start_sortie(sortie, pilot1.id)

      sortie = Campaigns.get_sortie!(sortie.id)

      # Set sortie as if SP was already distributed
      {:ok, sortie} =
        sortie
        |> Ecto.Changeset.change(%{
          mvp_pilot_id: pilot1.id,
          pilot_sp_cost: 100,
          finalization_step: "spend_sp"
        })
        |> Aces.Repo.update()

      %{sortie: sortie, pilot1: pilot1, pilot2: pilot2, all_pilots: [pilot1, pilot2]}
    end

    test "changes MVP and updates both pilots", %{
      sortie: sortie,
      pilot1: pilot1,
      pilot2: pilot2,
      all_pilots: all_pilots
    } do
      initial_pilot1_sp = pilot1.sp_earned
      initial_pilot2_sp = pilot2.sp_earned

      assert {:ok, updated_sortie} = Campaigns.handle_mvp_change(sortie, pilot1.id, pilot2.id, all_pilots)

      # Check sortie was updated
      assert updated_sortie.mvp_pilot_id == pilot2.id
      assert updated_sortie.finalization_step == "spend_sp"

      # Reload pilots
      pilot1_updated = Aces.Repo.get!(Aces.Companies.Pilot, pilot1.id)
      pilot2_updated = Aces.Repo.get!(Aces.Companies.Pilot, pilot2.id)

      # Old MVP should lose bonus
      assert pilot1_updated.sp_earned == max(initial_pilot1_sp - 20, 0)
      assert pilot1_updated.mvp_awards == max((pilot1.mvp_awards || 0) - 1, 0)

      # New MVP should gain bonus
      assert pilot2_updated.sp_earned == initial_pilot2_sp + 20
      assert pilot2_updated.mvp_awards == (pilot2.mvp_awards || 0) + 1
    end

    test "handles no MVP change", %{sortie: sortie, pilot1: pilot1, all_pilots: all_pilots} do
      assert {:ok, updated_sortie} = Campaigns.handle_mvp_change(sortie, pilot1.id, pilot1.id, all_pilots)

      # Sortie should just update step
      assert updated_sortie.mvp_pilot_id == pilot1.id
      assert updated_sortie.finalization_step == "spend_sp"
    end

    test "handles changing from MVP to no MVP", %{
      sortie: sortie,
      pilot1: pilot1,
      all_pilots: all_pilots
    } do
      initial_pilot1_sp = pilot1.sp_earned

      assert {:ok, updated_sortie} = Campaigns.handle_mvp_change(sortie, pilot1.id, nil, all_pilots)

      assert updated_sortie.mvp_pilot_id == nil

      # Reload pilot
      pilot1_updated = Aces.Repo.get!(Aces.Companies.Pilot, pilot1.id)

      # Should lose MVP bonus
      assert pilot1_updated.sp_earned == max(initial_pilot1_sp - 20, 0)
      assert pilot1_updated.mvp_awards == max((pilot1.mvp_awards || 0) - 1, 0)
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