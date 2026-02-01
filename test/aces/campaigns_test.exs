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

  describe "purchase_unit_for_campaign/3" do
    setup do
      user = user_fixture()
      # Create active company for purchases
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company, %{"warchest_balance" => 5000})

      # Create a master unit for purchase
      master_unit = units_master_unit_fixture(%{
        point_value: 45,
        unit_type: "battlemech"
      })

      %{
        user: user,
        company: company,
        campaign: campaign,
        master_unit: master_unit
      }
    end

    test "purchases unit and deducts SP from warchest", %{
      campaign: campaign,
      master_unit: master_unit
    } do
      # Unit cost = 45 PV * 40 = 1800 SP
      assert {:ok, company_unit} = Campaigns.purchase_unit_for_campaign(campaign, master_unit.mul_id)

      assert company_unit.master_unit_id == master_unit.id
      assert company_unit.purchase_cost_sp == 1800
      assert company_unit.company_id == campaign.company_id

      # Reload campaign to verify warchest was updated
      updated_campaign = Campaigns.get_campaign!(campaign.id)
      assert updated_campaign.warchest_balance == 5000 - 1800
    end

    test "creates campaign event for purchase", %{
      campaign: campaign,
      master_unit: master_unit
    } do
      assert {:ok, _company_unit} = Campaigns.purchase_unit_for_campaign(campaign, master_unit.mul_id)

      # Reload campaign to check events
      updated_campaign = Campaigns.get_campaign!(campaign.id)

      # Find the unit_purchased event
      purchase_event = Enum.find(updated_campaign.campaign_events, fn e ->
        e.event_type == "unit_purchased"
      end)

      assert purchase_event != nil
      assert purchase_event.description =~ "1800 SP"
    end

    test "fails when campaign is not active", %{master_unit: master_unit, campaign: campaign} do
      # Complete the existing campaign
      {:ok, completed_campaign} = Campaigns.complete_campaign(campaign, "completed")

      assert {:error, message} = Campaigns.purchase_unit_for_campaign(completed_campaign, master_unit.mul_id)
      assert message =~ "campaign is completed"
    end

    test "fails when sortie is in progress", %{campaign: campaign, company: company, master_unit: master_unit} do
      pilot = pilot_fixture(company: company)
      unit = company_unit_fixture(company: company, master_unit: master_unit)

      # Create and start a sortie
      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Test Sortie",
        "pv_limit" => 200
      })

      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: unit.id,
        pilot_id: pilot.id
      })

      sortie = Campaigns.get_sortie!(sortie.id)
      {:ok, _started_sortie} = Campaigns.start_sortie(sortie, pilot.id)

      # Reload campaign to get updated sorties
      campaign_with_sortie = Campaigns.get_campaign!(campaign.id)

      # Create a new master unit for the purchase attempt
      new_master_unit = units_master_unit_fixture(%{
        point_value: 30,
        unit_type: "battlemech"
      })

      # Try to purchase - should fail
      assert {:error, message} = Campaigns.purchase_unit_for_campaign(campaign_with_sortie, new_master_unit.mul_id)
      assert message =~ "sortie is in progress"
    end

    test "fails when insufficient SP in warchest", %{master_unit: master_unit} do
      # Create a separate company for this test with limited warchest
      user = user_fixture()
      poor_company = company_fixture(user: user, status: "active")
      poor_campaign = campaign_fixture(poor_company, %{"warchest_balance" => 100})

      assert {:error, %Ecto.Changeset{} = changeset} = Campaigns.purchase_unit_for_campaign(poor_campaign, master_unit.mul_id)
      errors = Aces.DataCase.errors_on(changeset)
      assert errors[:master_unit_id] != nil
      assert Enum.any?(errors.master_unit_id, &(&1 =~ "Insufficient SP"))
    end
  end

  describe "can_purchase_units?/1" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company, %{"warchest_balance" => 5000})

      %{company: company, campaign: campaign}
    end

    test "returns true for active campaign with no in-progress sortie", %{campaign: campaign} do
      assert Campaigns.can_purchase_units?(campaign) == true
    end

    test "returns false when campaign is not active", %{campaign: campaign} do
      {:ok, completed_campaign} = Campaigns.complete_campaign(campaign, "completed")
      assert Campaigns.can_purchase_units?(completed_campaign) == false
    end

    test "returns false when sortie is in progress", %{campaign: campaign, company: company} do
      pilot = pilot_fixture(company: company)
      master_unit = units_master_unit_fixture()
      unit = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Test Sortie",
        "pv_limit" => 200
      })

      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: unit.id,
        pilot_id: pilot.id
      })

      sortie = Campaigns.get_sortie!(sortie.id)
      {:ok, _started_sortie} = Campaigns.start_sortie(sortie, pilot.id)

      # Reload campaign with sorties
      campaign_with_sortie = Campaigns.get_campaign!(campaign.id)

      assert Campaigns.can_purchase_units?(campaign_with_sortie) == false
    end
  end

  describe "can_sell_unit?/1" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company, %{"warchest_balance" => 5000})
      pilot = pilot_fixture(company: company)
      master_unit = units_master_unit_fixture(%{point_value: 40})
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      %{
        company: company,
        campaign: campaign,
        pilot: pilot,
        company_unit: company_unit
      }
    end

    test "returns true when unit is not deployed in any sortie", %{company_unit: company_unit} do
      assert Campaigns.can_sell_unit?(company_unit) == true
    end

    test "returns false when unit is deployed in setup sortie", %{
      company_unit: company_unit,
      campaign: campaign,
      pilot: pilot
    } do
      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Test Sortie",
        "pv_limit" => 200
      })

      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      })

      assert Campaigns.can_sell_unit?(company_unit) == false
    end

    test "returns false when unit is deployed in in_progress sortie", %{
      company_unit: company_unit,
      campaign: campaign,
      pilot: pilot
    } do
      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Test Sortie",
        "pv_limit" => 200
      })

      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      })

      sortie = Campaigns.get_sortie!(sortie.id)
      {:ok, _started} = Campaigns.start_sortie(sortie, pilot.id)

      assert Campaigns.can_sell_unit?(company_unit) == false
    end

    test "returns true when unit was deployed in completed sortie", %{
      company_unit: company_unit,
      campaign: campaign,
      company: _company,
      pilot: pilot
    } do
      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Test Sortie",
        "pv_limit" => 200
      })

      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      })

      sortie = Campaigns.get_sortie!(sortie.id)
      {:ok, sortie} = Campaigns.start_sortie(sortie, pilot.id)

      # Complete the sortie
      sortie =
        Aces.Campaigns.Sortie
        |> Aces.Repo.get!(sortie.id)
        |> Aces.Repo.preload([
          :force_commander,
          :mvp_pilot,
          campaign: [company: :pilots],
          deployments: [company_unit: :master_unit, pilot: []]
        ])

      {:ok, _completed} = Campaigns.complete_sortie(sortie, %{
        was_successful: true,
        sp_per_participating_pilot: 50,
        primary_objective_income: 200
      })

      # Reload the company_unit
      company_unit = Aces.Repo.get!(Aces.Companies.CompanyUnit, company_unit.id)

      # Now unit should be sellable since sortie is completed
      assert Campaigns.can_sell_unit?(company_unit) == true
    end
  end

  describe "get_unit_active_sortie/1" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company, %{"warchest_balance" => 5000})
      pilot = pilot_fixture(company: company)
      master_unit = units_master_unit_fixture(%{point_value: 40})
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      %{
        company: company,
        campaign: campaign,
        pilot: pilot,
        company_unit: company_unit
      }
    end

    test "returns nil when unit is not deployed", %{company_unit: company_unit} do
      assert Campaigns.get_unit_active_sortie(company_unit) == nil
    end

    test "returns sortie when unit is deployed in active sortie", %{
      company_unit: company_unit,
      campaign: campaign,
      pilot: pilot
    } do
      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Active Sortie",
        "pv_limit" => 200
      })

      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      })

      result = Campaigns.get_unit_active_sortie(company_unit)
      assert result.id == sortie.id
      assert result.name == "Active Sortie"
    end
  end

  describe "sell_unit/2" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company, %{"warchest_balance" => 1000})
      master_unit = units_master_unit_fixture(%{point_value: 40})
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      %{
        company: company,
        campaign: campaign,
        company_unit: company_unit,
        master_unit: master_unit
      }
    end

    test "sells unit and refunds SP to warchest", %{
      company_unit: company_unit,
      campaign: campaign,
      master_unit: master_unit
    } do
      # Sell price = (40 PV * 40) / 2 = 800 SP
      expected_sell_price = div(master_unit.point_value * 40, 2)

      assert {:ok, sell_price} = Campaigns.sell_unit(company_unit, campaign)
      assert sell_price == expected_sell_price

      # Verify unit was deleted
      assert Aces.Repo.get(Aces.Companies.CompanyUnit, company_unit.id) == nil

      # Verify warchest was updated
      updated_campaign = Campaigns.get_campaign!(campaign.id)
      assert updated_campaign.warchest_balance == 1000 + expected_sell_price
    end

    test "creates campaign event for sale", %{
      company_unit: company_unit,
      campaign: campaign
    } do
      {:ok, _sell_price} = Campaigns.sell_unit(company_unit, campaign)

      updated_campaign = Campaigns.get_campaign!(campaign.id)

      # Find the unit_sold event
      sell_event = Enum.find(updated_campaign.campaign_events, fn e ->
        e.event_type == "unit_sold"
      end)

      assert sell_event != nil
      assert sell_event.description =~ "Sold"
      assert sell_event.description =~ "SP"
    end

    test "fails when unit is deployed in active sortie", %{
      company_unit: company_unit,
      campaign: campaign,
      company: company
    } do
      pilot = pilot_fixture(company: company)

      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Active Sortie",
        "pv_limit" => 200
      })

      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      })

      assert {:error, message} = Campaigns.sell_unit(company_unit, campaign)
      assert message =~ "Cannot sell unit"
      assert message =~ "Sortie 1"
    end
  end

  describe "complete_sortie/3 with deployment results" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company, %{"warchest_balance" => 5000})
      pilot = pilot_fixture(company: company)

      master_unit = units_master_unit_fixture(%{bf_size: 2})
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, sortie} =
        Campaigns.create_sortie(campaign, %{
          "mission_number" => "1",
          "name" => "Complete Test",
          "pv_limit" => 200
        })

      {:ok, _deployment} =
        Campaigns.create_deployment(sortie, %{
          company_unit_id: company_unit.id,
          pilot_id: pilot.id
        })

      sortie = Campaigns.get_sortie!(sortie.id)
      {:ok, started_sortie} = Campaigns.start_sortie(sortie, pilot.id)

      # Reload sortie with all required associations for complete_sortie
      # complete_sortie needs campaign.company.pilots for pilot awards
      started_sortie =
        Aces.Campaigns.Sortie
        |> Aces.Repo.get!(started_sortie.id)
        |> Aces.Repo.preload([
          :force_commander,
          :mvp_pilot,
          campaign: [company: :pilots],
          deployments: [company_unit: :master_unit, pilot: []]
        ])

      deployment = hd(started_sortie.deployments)

      %{
        sortie: started_sortie,
        deployment: deployment,
        campaign: campaign,
        company: company,
        pilot: pilot,
        company_unit: company_unit
      }
    end

    test "updates deployment results successfully", %{sortie: sortie, deployment: deployment} do
      completion_attrs = %{
        was_successful: true,
        sp_per_participating_pilot: 100,
        primary_objective_income: 500
      }

      deployment_results = [
        {deployment.id, %{damage_status: "structure_damaged", pilot_casualty: "none"}}
      ]

      assert {:ok, completed_sortie} = Campaigns.complete_sortie(sortie, completion_attrs, deployment_results)

      # Verify the deployment was updated
      updated_deployment = Enum.find(completed_sortie.deployments, &(&1.id == deployment.id))
      assert updated_deployment.damage_status == "structure_damaged"
      assert updated_deployment.pilot_casualty == "none"
      # Repair cost should be size * 40 for structure damage
      # Size 2 * 40 = 80
      assert updated_deployment.repair_cost_sp == 80
    end

    test "calculates repair costs correctly for different damage levels", %{
      sortie: sortie,
      deployment: deployment
    } do
      completion_attrs = %{
        was_successful: true,
        sp_per_participating_pilot: 100,
        primary_objective_income: 500
      }

      # Test with crippled damage
      deployment_results = [
        {deployment.id, %{damage_status: "crippled", pilot_casualty: "none"}}
      ]

      assert {:ok, completed_sortie} = Campaigns.complete_sortie(sortie, completion_attrs, deployment_results)

      updated_deployment = Enum.find(completed_sortie.deployments, &(&1.id == deployment.id))
      # Crippled = size * 60 = 2 * 60 = 120
      assert updated_deployment.repair_cost_sp == 120
    end

    test "handles multiple deployment updates atomically", %{
      sortie: sortie,
      company: company
    } do
      # Create second pilot and unit for multi-update test
      pilot2 = pilot_fixture(company: company, name: "Pilot 2")
      master_unit2 = units_master_unit_fixture(%{name: "Unit 2", bf_size: 3})
      company_unit2 = company_unit_fixture(company: company, master_unit: master_unit2)

      {:ok, _deployment2} =
        Campaigns.create_deployment(sortie, %{
          company_unit_id: company_unit2.id,
          pilot_id: pilot2.id
        })

      # Reload sortie with all required associations for complete_sortie
      sortie =
        Aces.Campaigns.Sortie
        |> Aces.Repo.get!(sortie.id)
        |> Aces.Repo.preload([
          :force_commander,
          :mvp_pilot,
          campaign: [company: :pilots],
          deployments: [company_unit: :master_unit, pilot: []]
        ])

      [dep1, dep2] = sortie.deployments

      completion_attrs = %{
        was_successful: true,
        sp_per_participating_pilot: 100,
        primary_objective_income: 500
      }

      deployment_results = [
        {dep1.id, %{damage_status: "armor_damaged", pilot_casualty: "none"}},
        {dep2.id, %{damage_status: "destroyed", pilot_casualty: "wounded"}}
      ]

      assert {:ok, completed_sortie} = Campaigns.complete_sortie(sortie, completion_attrs, deployment_results)

      updated_dep1 = Enum.find(completed_sortie.deployments, &(&1.id == dep1.id))
      updated_dep2 = Enum.find(completed_sortie.deployments, &(&1.id == dep2.id))

      assert updated_dep1.damage_status == "armor_damaged"
      assert updated_dep2.damage_status == "destroyed"
      assert updated_dep2.pilot_casualty == "wounded"
    end

    test "rolls back all changes when deployment update fails with invalid data", %{
      sortie: sortie,
      deployment: deployment
    } do
      completion_attrs = %{
        was_successful: true,
        sp_per_participating_pilot: 100,
        primary_objective_income: 500
      }

      # Invalid damage_status should cause validation error
      deployment_results = [
        {deployment.id, %{damage_status: "invalid_status", pilot_casualty: "none"}}
      ]

      assert {:error, error} = Campaigns.complete_sortie(sortie, completion_attrs, deployment_results)

      # Error should indicate the deployment update failed
      assert match?({:deployment_update_failed, _, %Ecto.Changeset{}}, error)

      # Sortie should remain unchanged
      unchanged_sortie = Campaigns.get_sortie!(sortie.id)
      assert unchanged_sortie.status == "in_progress"
    end
  end

  describe "can_hire_pilots?/1" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company, %{"warchest_balance" => 500})

      %{user: user, company: company, campaign: campaign}
    end

    test "returns true when campaign is active, no sorties in progress, and has sufficient funds", %{
      campaign: campaign
    } do
      assert Campaigns.can_hire_pilots?(campaign) == true
    end

    test "returns false when campaign is not active", %{campaign: campaign} do
      {:ok, completed_campaign} = Campaigns.complete_campaign(campaign, "completed")
      assert Campaigns.can_hire_pilots?(completed_campaign) == false
    end

    test "returns false when sortie is in progress", %{campaign: campaign, company: company} do
      # Create a pilot and unit for deployment
      pilot = pilot_fixture(company: company)
      master_unit = units_master_unit_fixture()
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, sortie} =
        Campaigns.create_sortie(campaign, %{
          "mission_number" => "1",
          "name" => "Test",
          "pv_limit" => 100
        })

      # Add a deployment
      {:ok, _deployment} =
        Campaigns.create_deployment(sortie, %{
          company_unit_id: company_unit.id,
          pilot_id: pilot.id
        })

      # Reload sortie with deployments
      sortie = Campaigns.get_sortie!(sortie.id)

      {:ok, _started_sortie} = Campaigns.start_sortie(sortie, pilot.id)

      # Reload campaign
      updated_campaign = Campaigns.get_campaign!(campaign.id)
      assert Campaigns.can_hire_pilots?(updated_campaign) == false
    end

    test "returns false when campaign has insufficient funds", %{user: user} do
      # Create new company for separate campaign with less than 150 SP
      company2 = company_fixture(user: user)
      low_funds_campaign = campaign_fixture(company2, %{"warchest_balance" => 100})
      assert Campaigns.can_hire_pilots?(low_funds_campaign) == false
    end

    test "returns true when campaign has exactly 150 SP", %{user: user} do
      # Create new company for separate campaign with exactly 150 SP
      company2 = company_fixture(user: user)
      exact_funds_campaign = campaign_fixture(company2, %{"warchest_balance" => 150})
      assert Campaigns.can_hire_pilots?(exact_funds_campaign) == true
    end
  end

  describe "hire_pilot_for_campaign/2" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company, %{"warchest_balance" => 500})

      %{user: user, company: company, campaign: campaign}
    end

    test "hires pilot and deducts 150 SP from campaign warchest", %{
      campaign: campaign,
      company: company
    } do
      pilot_attrs = %{name: "New Pilot", callsign: "Rookie"}

      assert {:ok, pilot, updated_campaign} =
               Campaigns.hire_pilot_for_campaign(campaign, pilot_attrs)

      # Check pilot was created
      assert pilot.name == "New Pilot"
      assert pilot.callsign == "Rookie"
      assert pilot.skill_level == 4
      assert pilot.edge_tokens == 1
      assert pilot.status == "active"
      assert pilot.company_id == company.id

      # Check warchest was deducted
      assert updated_campaign.warchest_balance == campaign.warchest_balance - 150
    end

    test "creates initial PilotAllocation record for hired pilot", %{campaign: campaign} do
      pilot_attrs = %{name: "New Pilot"}

      assert {:ok, pilot, _updated_campaign} =
               Campaigns.hire_pilot_for_campaign(campaign, pilot_attrs)

      # Check allocation was created
      allocations = Aces.Repo.all(Aces.Campaigns.PilotAllocation)
      pilot_allocations = Enum.filter(allocations, &(&1.pilot_id == pilot.id))

      assert length(pilot_allocations) == 1
      allocation = hd(pilot_allocations)
      assert allocation.allocation_type == "initial"
      assert allocation.sp_to_skill == 0
      assert allocation.sp_to_tokens == 0
      assert allocation.sp_to_abilities == 0
    end

    test "creates campaign event for pilot hire", %{campaign: campaign} do
      pilot_attrs = %{name: "Hired Pilot", callsign: "Merc"}

      assert {:ok, _pilot, _updated_campaign} =
               Campaigns.hire_pilot_for_campaign(campaign, pilot_attrs)

      # Reload campaign with events
      updated_campaign = Campaigns.get_campaign!(campaign.id)

      hire_event =
        Enum.find(updated_campaign.campaign_events, &(&1.event_type == "pilot_hired"))

      assert hire_event != nil
      assert hire_event.description =~ "Hired pilot Hired Pilot"
      assert hire_event.description =~ "\"Merc\""
      assert hire_event.description =~ "150 SP"
    end

    test "fails when campaign is not active", %{campaign: campaign} do
      {:ok, completed_campaign} = Campaigns.complete_campaign(campaign, "completed")

      assert {:error, message} =
               Campaigns.hire_pilot_for_campaign(completed_campaign, %{name: "Test"})

      assert message =~ "campaign is completed"
    end

    test "fails when sortie is in progress", %{campaign: campaign, company: company} do
      # Create a pilot and unit for deployment
      pilot = pilot_fixture(company: company)
      master_unit = units_master_unit_fixture()
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, sortie} =
        Campaigns.create_sortie(campaign, %{
          "mission_number" => "1",
          "name" => "Test",
          "pv_limit" => 100
        })

      # Add a deployment
      {:ok, _deployment} =
        Campaigns.create_deployment(sortie, %{
          company_unit_id: company_unit.id,
          pilot_id: pilot.id
        })

      # Reload sortie with deployments
      sortie = Campaigns.get_sortie!(sortie.id)

      {:ok, _started_sortie} = Campaigns.start_sortie(sortie, pilot.id)

      # Reload campaign
      updated_campaign = Campaigns.get_campaign!(campaign.id)

      assert {:error, message} =
               Campaigns.hire_pilot_for_campaign(updated_campaign, %{name: "Test"})

      assert message =~ "sortie is in progress"
    end

    test "fails when campaign has insufficient funds", %{user: user} do
      # Create new company for separate campaign with insufficient funds
      company2 = company_fixture(user: user)
      low_funds_campaign = campaign_fixture(company2, %{"warchest_balance" => 100})

      assert {:error, message} =
               Campaigns.hire_pilot_for_campaign(low_funds_campaign, %{name: "Test"})

      assert message =~ "Insufficient SP"
      assert message =~ "need 150 SP"
      assert message =~ "have 100 SP"
    end

    test "fails when pilot name is missing", %{campaign: campaign} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Campaigns.hire_pilot_for_campaign(campaign, %{})

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "deducts exactly 150 SP when campaign has exactly 150 SP", %{user: user} do
      # Create new company for separate campaign with exactly 150 SP
      company2 = company_fixture(user: user)
      exact_funds_campaign = campaign_fixture(company2, %{"warchest_balance" => 150})

      assert {:ok, _pilot, updated_campaign} =
               Campaigns.hire_pilot_for_campaign(exact_funds_campaign, %{name: "Test"})

      assert updated_campaign.warchest_balance == 0
    end
  end

  describe "campaign event user tracking" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      %{user: user, company: company}
    end

    test "create_campaign/3 tracks user who started the campaign", %{user: user, company: company} do
      {:ok, campaign} = Campaigns.create_campaign(company, %{"name" => "Test Campaign"}, user: user)

      # Check that the campaign_started event has the user_id
      start_event = Enum.find(campaign.campaign_events, &(&1.event_type == "campaign_started"))
      assert start_event != nil
      assert start_event.user_id == user.id
      assert start_event.user.email == user.email
    end

    test "create_campaign/3 works without user", %{company: company} do
      {:ok, campaign} = Campaigns.create_campaign(company, %{"name" => "Test Campaign"})

      start_event = Enum.find(campaign.campaign_events, &(&1.event_type == "campaign_started"))
      assert start_event != nil
      assert start_event.user_id == nil
    end

    test "hire_pilot_for_campaign/3 tracks user who hired the pilot", %{user: user, company: company} do
      {:ok, campaign} = Campaigns.create_campaign(company, %{"name" => "Test Campaign"})

      {:ok, pilot, _updated_campaign} =
        Campaigns.hire_pilot_for_campaign(campaign, %{name: "Test Pilot"}, user: user)

      # Reload campaign to get fresh events with user preloaded
      updated_campaign = Campaigns.get_campaign!(campaign.id)
      hire_event = Enum.find(updated_campaign.campaign_events, &(&1.event_type == "pilot_hired"))

      assert hire_event != nil
      assert hire_event.user_id == user.id
      assert hire_event.event_data["pilot_name"] == pilot.name
    end

    test "purchase_unit_for_campaign/4 tracks user who purchased the unit", %{user: user} do
      # Use an active company for purchases
      active_company = company_fixture(user: user, status: "active")
      master_unit = units_master_unit_fixture()
      {:ok, campaign} = Campaigns.create_campaign(active_company, %{"name" => "Test", "warchest_balance" => 10000})

      {:ok, _company_unit} =
        Campaigns.purchase_unit_for_campaign(campaign, master_unit.mul_id, %{}, user: user)

      updated_campaign = Campaigns.get_campaign!(campaign.id)
      purchase_event = Enum.find(updated_campaign.campaign_events, &(&1.event_type == "unit_purchased"))

      assert purchase_event != nil
      assert purchase_event.user_id == user.id
    end

    test "sell_unit/3 tracks user who sold the unit", %{user: user, company: company} do
      master_unit = units_master_unit_fixture()
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)
      {:ok, campaign} = Campaigns.create_campaign(company, %{"name" => "Test"})

      {:ok, _sell_price} = Campaigns.sell_unit(company_unit, campaign, user: user)

      updated_campaign = Campaigns.get_campaign!(campaign.id)
      sell_event = Enum.find(updated_campaign.campaign_events, &(&1.event_type == "unit_sold"))

      assert sell_event != nil
      assert sell_event.user_id == user.id
    end

    test "complete_campaign/3 tracks user who completed the campaign", %{user: user, company: company} do
      {:ok, campaign} = Campaigns.create_campaign(company, %{"name" => "Test"})

      {:ok, completed_campaign} = Campaigns.complete_campaign(campaign, "completed", user: user)

      updated_campaign = Campaigns.get_campaign!(completed_campaign.id)
      complete_event = Enum.find(updated_campaign.campaign_events, &(&1.event_type == "campaign_completed"))

      assert complete_event != nil
      assert complete_event.user_id == user.id
    end
  end

  describe "complete_campaign/3 warchest sync" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user, warchest_balance: 1000, status: "active")

      %{user: user, company: company}
    end

    test "syncs campaign warchest balance to company warchest on completion", %{company: company} do
      # Create campaign - it should inherit company's warchest (1000 SP)
      {:ok, campaign} = Campaigns.create_campaign(company, %{"name" => "Test Campaign"})
      assert campaign.warchest_balance == 1000

      # Simulate campaign activity by updating warchest (normally done via sorties, purchases, etc.)
      {:ok, campaign} =
        Campaigns.update_campaign(campaign, %{warchest_balance: 2500})

      # Complete the campaign
      {:ok, completed_campaign} = Campaigns.complete_campaign(campaign, "completed")

      assert completed_campaign.status == "completed"
      assert completed_campaign.warchest_balance == 2500

      # Verify company warchest was updated to match campaign final balance
      updated_company = Aces.Companies.get_company!(company.id)
      assert updated_company.warchest_balance == 2500
    end

    test "syncs campaign warchest to company on failed campaign", %{company: company} do
      {:ok, campaign} = Campaigns.create_campaign(company, %{"name" => "Failed Campaign"})

      # Campaign lost money during failed campaign
      {:ok, campaign} =
        Campaigns.update_campaign(campaign, %{warchest_balance: 500})

      {:ok, failed_campaign} = Campaigns.complete_campaign(campaign, "failed")

      assert failed_campaign.status == "failed"

      # Company should still get the remaining warchest
      updated_company = Aces.Companies.get_company!(company.id)
      assert updated_company.warchest_balance == 500
    end

    test "syncs campaign warchest after unit purchases reduce balance", %{company: company} do
      {:ok, campaign} = Campaigns.create_campaign(company, %{"name" => "Purchase Campaign"})
      master_unit = units_master_unit_fixture(%{point_value: 10})

      # Purchase a unit (costs 10 PV × 40 = 400 SP)
      {:ok, _unit} = Campaigns.purchase_unit_for_campaign(campaign, master_unit.mul_id)

      # Reload campaign to get updated warchest
      campaign = Campaigns.get_campaign!(campaign.id)
      assert campaign.warchest_balance == 600

      # Complete the campaign
      {:ok, _completed} = Campaigns.complete_campaign(campaign, "completed")

      # Company warchest should be 600 SP (1000 - 400)
      updated_company = Aces.Companies.get_company!(company.id)
      assert updated_company.warchest_balance == 600
    end

    test "syncs campaign warchest after unit sales increase balance", %{company: company} do
      master_unit = units_master_unit_fixture(%{point_value: 20})
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, campaign} = Campaigns.create_campaign(company, %{"name" => "Sale Campaign"})

      # Sell a unit (refunds 20 PV × 20 = 400 SP)
      {:ok, _sell_price} = Campaigns.sell_unit(company_unit, campaign)

      campaign = Campaigns.get_campaign!(campaign.id)
      assert campaign.warchest_balance == 1400

      {:ok, _completed} = Campaigns.complete_campaign(campaign, "completed")

      # Company warchest should be 1400 SP (1000 + 400)
      updated_company = Aces.Companies.get_company!(company.id)
      assert updated_company.warchest_balance == 1400
    end

    test "syncs campaign warchest after hiring pilots", %{company: company} do
      {:ok, campaign} = Campaigns.create_campaign(company, %{"name" => "Hire Campaign"})

      # Hire a pilot (costs 150 SP)
      {:ok, _pilot, _updated_campaign} =
        Campaigns.hire_pilot_for_campaign(campaign, %{name: "New Recruit"})

      campaign = Campaigns.get_campaign!(campaign.id)
      assert campaign.warchest_balance == 850

      {:ok, _completed} = Campaigns.complete_campaign(campaign, "completed")

      # Company warchest should be 850 SP (1000 - 150)
      updated_company = Aces.Companies.get_company!(company.id)
      assert updated_company.warchest_balance == 850
    end
  end

  describe "can_reset_sortie?/1" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      %{campaign: campaign}
    end

    test "returns true for sortie in setup status", %{campaign: campaign} do
      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Test Mission",
        "pv_limit" => 200
      })

      assert sortie.status == "setup"
      assert Campaigns.can_reset_sortie?(sortie) == true
    end

    test "returns true for sortie in in_progress status", %{campaign: campaign} do
      sortie = create_started_sortie(campaign)
      assert sortie.status == "in_progress"
      assert Campaigns.can_reset_sortie?(sortie) == true
    end

    test "returns true for sortie in finalizing status", %{campaign: campaign} do
      sortie = create_started_sortie(campaign)
      {:ok, finalizing_sortie} = Campaigns.begin_sortie_finalization(sortie)
      assert finalizing_sortie.status == "finalizing"
      assert Campaigns.can_reset_sortie?(finalizing_sortie) == true
    end

    test "returns false for completed sortie", _ctx do
      completed_sortie = %Sortie{status: "completed"}
      assert Campaigns.can_reset_sortie?(completed_sortie) == false
    end

    test "returns false for failed sortie", _ctx do
      failed_sortie = %Sortie{status: "failed"}
      assert Campaigns.can_reset_sortie?(failed_sortie) == false
    end
  end

  describe "reset_sortie/1" do
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

    test "resets sortie from setup status", %{campaign: campaign, pilot: pilot, company_unit: company_unit} do
      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Test Mission",
        "pv_limit" => 200
      })

      # Add a deployment
      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      })

      sortie = Campaigns.get_sortie!(sortie.id)
      assert length(sortie.deployments) == 1

      {:ok, reset_sortie} = Campaigns.reset_sortie(sortie)

      assert reset_sortie.status == "setup"
      assert reset_sortie.started_at == nil
      assert reset_sortie.force_commander_id == nil
      # Deployment should be preserved
      assert length(reset_sortie.deployments) == 1
    end

    test "resets sortie from in_progress status and clears damage", %{
      campaign: campaign,
      pilot: pilot,
      company_unit: company_unit
    } do
      sortie = create_started_sortie_with_unit(campaign, pilot, company_unit)

      # Simulate some damage
      deployment = hd(sortie.deployments)
      {:ok, _} = Campaigns.update_deployment_damage_status(deployment, "crippled")
      {:ok, _} = Campaigns.update_deployment_casualty(deployment, "wounded")

      sortie = Campaigns.get_sortie!(sortie.id)
      deployment = hd(sortie.deployments)
      assert deployment.damage_status == "crippled"
      assert deployment.pilot_casualty == "wounded"

      {:ok, reset_sortie} = Campaigns.reset_sortie(sortie)

      assert reset_sortie.status == "setup"
      assert reset_sortie.started_at == nil
      assert reset_sortie.force_commander_id == nil

      # Deployment should be reset to operational
      reset_deployment = hd(reset_sortie.deployments)
      assert reset_deployment.damage_status == "operational"
      assert reset_deployment.pilot_casualty == "none"
    end

    test "resets sortie from finalizing status", %{campaign: campaign, pilot: pilot, company_unit: company_unit} do
      sortie = create_started_sortie_with_unit(campaign, pilot, company_unit)

      # Begin finalization
      {:ok, finalizing_sortie} = Campaigns.begin_sortie_finalization(sortie)
      assert finalizing_sortie.status == "finalizing"
      assert finalizing_sortie.finalization_step == "outcome"

      {:ok, reset_sortie} = Campaigns.reset_sortie(finalizing_sortie)

      assert reset_sortie.status == "setup"
      assert reset_sortie.finalization_step == nil
    end

    test "clears finalization fields on reset", %{campaign: campaign, pilot: pilot, company_unit: company_unit} do
      sortie = create_started_sortie_with_unit(campaign, pilot, company_unit)

      # Begin finalization and update some fields
      {:ok, finalizing_sortie} = Campaigns.begin_sortie_finalization(sortie)
      {:ok, updated_sortie} = Aces.Repo.update(
        Sortie.finalization_step_changeset(finalizing_sortie, "damage", %{
          primary_objective_income: 100,
          secondary_objectives_income: 50,
          keywords_gained: ["Veteran"]
        })
      )

      assert updated_sortie.primary_objective_income == 100
      assert updated_sortie.secondary_objectives_income == 50
      assert updated_sortie.keywords_gained == ["Veteran"]

      {:ok, reset_sortie} = Campaigns.reset_sortie(updated_sortie)

      assert reset_sortie.status == "setup"
      assert reset_sortie.primary_objective_income == 0
      assert reset_sortie.secondary_objectives_income == 0
      assert reset_sortie.waypoints_income == 0
      assert reset_sortie.total_income == 0
      assert reset_sortie.total_expenses == 0
      assert reset_sortie.net_earnings == 0
      assert reset_sortie.keywords_gained == []
      assert reset_sortie.was_successful == nil
      assert reset_sortie.mvp_pilot_id == nil
    end

    test "preserves sortie metadata on reset", %{campaign: campaign, pilot: pilot, company_unit: company_unit} do
      {:ok, sortie} = Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Important Mission",
        "description" => "A test mission",
        "pv_limit" => 250,
        "recon_notes" => "Scouting report"
      })

      {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit.id,
        pilot_id: pilot.id
      })

      sortie = Campaigns.get_sortie!(sortie.id)
      {:ok, started_sortie} = Campaigns.start_sortie(sortie, pilot.id)
      {:ok, reset_sortie} = Campaigns.reset_sortie(started_sortie)

      # These should be preserved
      assert reset_sortie.mission_number == "1"
      assert reset_sortie.name == "Important Mission"
      assert reset_sortie.description == "A test mission"
      assert reset_sortie.pv_limit == 250
      assert reset_sortie.recon_notes == "Scouting report"
    end

    test "returns error for completed sortie", %{campaign: campaign} do
      completed_sortie = %Sortie{
        id: 999,
        status: "completed",
        campaign_id: campaign.id
      }

      assert {:error, "Cannot reset a completed or failed sortie"} =
               Campaigns.reset_sortie(completed_sortie)
    end

    test "returns error for failed sortie", %{campaign: campaign} do
      failed_sortie = %Sortie{
        id: 999,
        status: "failed",
        campaign_id: campaign.id
      }

      assert {:error, "Cannot reset a completed or failed sortie"} =
               Campaigns.reset_sortie(failed_sortie)
    end

    test "deletes pilot allocations on reset", %{campaign: campaign, pilot: pilot, company_unit: company_unit} do
      sortie = create_started_sortie_with_unit(campaign, pilot, company_unit)

      # Begin finalization
      {:ok, finalizing_sortie} = Campaigns.begin_sortie_finalization(sortie)

      # Create a pilot allocation
      {:ok, _} = Campaigns.save_sortie_pilot_allocations(finalizing_sortie.id, %{
        pilot.id => %{
          add_skill: 10,
          add_tokens: 0,
          add_abilities: 0,
          new_edge_abilities: [],
          sp_to_spend: 10
        }
      })

      # Verify allocation exists
      allocations = Campaigns.get_sortie_pilot_allocations(finalizing_sortie.id)
      assert length(allocations) == 1

      # Reset the sortie
      {:ok, _reset_sortie} = Campaigns.reset_sortie(finalizing_sortie)

      # Verify allocations were deleted
      allocations_after = Campaigns.get_sortie_pilot_allocations(finalizing_sortie.id)
      assert allocations_after == []
    end
  end

  # Helper function to create a started sortie with deployments
  defp create_started_sortie(campaign) do
    _user = user_fixture()
    company = Aces.Companies.get_company!(campaign.company_id)
    pilot = pilot_fixture(company: company)
    master_unit = units_master_unit_fixture()
    company_unit = company_unit_fixture(company: company, master_unit: master_unit)

    create_started_sortie_with_unit(campaign, pilot, company_unit)
  end

  defp create_started_sortie_with_unit(campaign, pilot, company_unit) do
    {:ok, sortie} = Campaigns.create_sortie(campaign, %{
      "mission_number" => "#{System.unique_integer([:positive])}",
      "name" => "Test Mission",
      "pv_limit" => 200
    })

    {:ok, _deployment} = Campaigns.create_deployment(sortie, %{
      company_unit_id: company_unit.id,
      pilot_id: pilot.id
    })

    sortie = Campaigns.get_sortie!(sortie.id)
    {:ok, started_sortie} = Campaigns.start_sortie(sortie, pilot.id)
    Campaigns.get_sortie!(started_sortie.id)
  end
end