defmodule Aces.Campaigns.SortieCompletionTest do
  use Aces.DataCase

  alias Aces.Campaigns.SortieCompletion
  alias Aces.Campaigns.{Sortie, Deployment}
  alias Aces.Companies.Pilot

  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures
  import Aces.UnitsFixtures

  describe "calculate_all_costs/1" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      pilot1 = pilot_fixture(company: company, name: "Pilot 1", callsign: "Alpha")
      pilot2 = pilot_fixture(company: company, name: "Pilot 2", callsign: "Beta")

      # Create units with different sizes
      master_unit1 = units_master_unit_fixture(%{name: "Mech 1", bf_size: 4})
      master_unit2 = units_master_unit_fixture(%{name: "Tank 1", bf_size: 3, unit_type: "combat_vehicle"})
      company_unit1 = company_unit_fixture(company: company, master_unit: master_unit1)
      company_unit2 = company_unit_fixture(company: company, master_unit: master_unit2)

      # Create sortie
      {:ok, sortie} = Aces.Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Test Mission",
        "pv_limit" => 200,
        "recon_total_cost" => 10
      })

      # Set income data (these are set during completion wizard, not creation)
      {:ok, sortie} = Aces.Repo.update(Ecto.Changeset.change(sortie, %{
        primary_objective_income: 200,
        secondary_objectives_income: 50,
        waypoints_income: 25
      }))

      # Create deployments
      {:ok, deployment1} = Aces.Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit1.id,
        pilot_id: pilot1.id
      })
      {:ok, deployment2} = Aces.Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit2.id,
        pilot_id: pilot2.id
      })

      # Reload sortie with all associations
      sortie = Aces.Campaigns.get_sortie!(sortie.id)

      %{
        sortie: sortie,
        campaign: campaign,
        pilot1: pilot1,
        pilot2: pilot2,
        company_unit1: company_unit1,
        company_unit2: company_unit2
      }
    end

    test "calculates costs for operational units", %{sortie: sortie} do
      costs = SortieCompletion.calculate_all_costs(sortie)

      assert costs.total_repair == 0  # Both operational
      assert costs.total_rearming == 40  # 20 SP each for 2 units
      assert costs.total_casualty == 0  # No casualties
      assert costs.total_expenses == 40

      # Income calculations: (200 + 50 + 25 - 10) * 1.0 (standard modifier)
      assert costs.base_income == 265
      assert costs.adjusted_income == 265
      assert costs.net_earnings == 225  # 265 - 40
    end

    test "calculates repair costs based on damage status", %{sortie: sortie} do
      # Update deployments with damage
      [deployment1, deployment2] = sortie.deployments

      # Crippled mech (size 4): 4 * 60 = 240 SP
      {:ok, _} = Aces.Repo.update(Ecto.Changeset.change(deployment1, damage_status: "crippled"))
      # Structure damaged tank (size 3, halved for vehicle): 1.5 * 40 = 60 SP
      {:ok, _} = Aces.Repo.update(Ecto.Changeset.change(deployment2, damage_status: "structure_damaged"))

      # Reload sortie
      sortie = Aces.Campaigns.get_sortie!(sortie.id)
      costs = SortieCompletion.calculate_all_costs(sortie)

      assert costs.total_repair == 300  # 240 + 60
    end

    test "treats salvaged destroyed units as salvageable for repair costs", %{sortie: sortie} do
      [deployment1, _] = sortie.deployments

      # Destroyed but salvaged mech (size 4): 4 * 100 = 400 SP (salvageable rate)
      {:ok, _} = Aces.Repo.update(Ecto.Changeset.change(deployment1, %{
        damage_status: "destroyed",
        was_salvaged: true
      }))

      sortie = Aces.Campaigns.get_sortie!(sortie.id)
      costs = SortieCompletion.calculate_all_costs(sortie)

      repair_cost_for_deployment1 = Map.get(costs.repair_costs, deployment1.id)
      assert repair_cost_for_deployment1 == 400
    end

    test "calculates casualty costs for wounded/killed pilots", %{sortie: sortie} do
      [deployment1, deployment2] = sortie.deployments

      {:ok, _} = Aces.Repo.update(Ecto.Changeset.change(deployment1, pilot_casualty: "wounded"))
      {:ok, _} = Aces.Repo.update(Ecto.Changeset.change(deployment2, pilot_casualty: "killed"))

      sortie = Aces.Campaigns.get_sortie!(sortie.id)
      costs = SortieCompletion.calculate_all_costs(sortie)

      assert costs.total_casualty == 200  # 100 SP each
      assert Map.get(costs.casualty_costs, deployment1.id) == 100
      assert Map.get(costs.casualty_costs, deployment2.id) == 100
    end
  end

  describe "calculate_pilot_earnings/3" do
    setup do
      user = user_fixture()
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      pilot1 = pilot_fixture(company: company, name: "Pilot 1", callsign: "Alpha")
      pilot2 = pilot_fixture(company: company, name: "Pilot 2", callsign: "Beta")
      pilot3 = pilot_fixture(company: company, name: "Pilot 3", callsign: "Gamma")

      master_unit = units_master_unit_fixture()
      company_unit1 = company_unit_fixture(company: company, master_unit: master_unit)
      company_unit2 = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, sortie} = Aces.Campaigns.create_sortie(campaign, %{
        "mission_number" => "1",
        "name" => "Test Mission",
        "pv_limit" => 200
      })

      # Set sp_per_participating_pilot (set during completion wizard)
      {:ok, sortie} = Aces.Repo.update(Ecto.Changeset.change(sortie, %{
        sp_per_participating_pilot: 100
      }))

      # Deploy pilot1 and pilot2, but not pilot3
      {:ok, _} = Aces.Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit1.id,
        pilot_id: pilot1.id
      })
      {:ok, _} = Aces.Campaigns.create_deployment(sortie, %{
        company_unit_id: company_unit2.id,
        pilot_id: pilot2.id
      })

      sortie = Aces.Campaigns.get_sortie!(sortie.id)

      # Update net_earnings on sortie
      {:ok, sortie} = Aces.Repo.update(Ecto.Changeset.change(sortie, net_earnings: 300))
      sortie = Aces.Campaigns.get_sortie!(sortie.id)

      %{
        sortie: sortie,
        all_pilots: [pilot1, pilot2, pilot3],
        pilot1: pilot1,
        pilot2: pilot2,
        pilot3: pilot3,
        participating_ids: MapSet.new([pilot1.id, pilot2.id])
      }
    end

    test "participating pilots earn full share", %{
      sortie: sortie,
      all_pilots: all_pilots,
      pilot1: pilot1,
      pilot2: pilot2,
      participating_ids: participating_ids
    } do
      earnings = SortieCompletion.calculate_pilot_earnings(sortie, all_pilots, participating_ids)

      assert Map.get(earnings, pilot1.id).sp == 100
      assert Map.get(earnings, pilot1.id).participated == true
      assert Map.get(earnings, pilot2.id).sp == 100
      assert Map.get(earnings, pilot2.id).participated == true
    end

    test "non-participating pilots earn half share", %{
      sortie: sortie,
      all_pilots: all_pilots,
      pilot3: pilot3,
      participating_ids: participating_ids
    } do
      earnings = SortieCompletion.calculate_pilot_earnings(sortie, all_pilots, participating_ids)

      assert Map.get(earnings, pilot3.id).sp == 50  # Half of 100
      assert Map.get(earnings, pilot3.id).participated == false
    end

    test "killed pilots earn nothing", %{
      sortie: sortie,
      all_pilots: all_pilots,
      pilot1: pilot1,
      participating_ids: participating_ids
    } do
      # Mark pilot1 as killed
      [deployment1 | _] = sortie.deployments
      {:ok, _} = Aces.Repo.update(Ecto.Changeset.change(deployment1, pilot_casualty: "killed"))
      sortie = Aces.Campaigns.get_sortie!(sortie.id)

      earnings = SortieCompletion.calculate_pilot_earnings(sortie, all_pilots, participating_ids)

      assert Map.get(earnings, pilot1.id).sp == 0
      assert Map.get(earnings, pilot1.id).status == :killed
    end

    test "scales earnings when pool is insufficient", %{
      sortie: sortie,
      all_pilots: all_pilots,
      participating_ids: participating_ids
    } do
      # Set net_earnings to 100, but total desired is 250 (100 + 100 + 50)
      {:ok, sortie} = Aces.Repo.update(Ecto.Changeset.change(sortie, net_earnings: 100))
      sortie = Aces.Campaigns.get_sortie!(sortie.id)

      earnings = SortieCompletion.calculate_pilot_earnings(sortie, all_pilots, participating_ids)

      # Total earned should not exceed 100
      total_earned = Enum.reduce(earnings, 0, fn {_id, data}, acc -> acc + data.sp end)
      assert total_earned <= 100
    end

    test "no earnings when net_earnings is zero or negative", %{
      sortie: sortie,
      all_pilots: all_pilots,
      participating_ids: participating_ids
    } do
      {:ok, sortie} = Aces.Repo.update(Ecto.Changeset.change(sortie, net_earnings: -50))
      sortie = Aces.Campaigns.get_sortie!(sortie.id)

      earnings = SortieCompletion.calculate_pilot_earnings(sortie, all_pilots, participating_ids)

      Enum.each(earnings, fn {_id, data} ->
        assert data.sp == 0
      end)
    end
  end

  describe "effective_damage_status/1" do
    test "returns salvageable for destroyed and salvaged units" do
      deployment = %{damage_status: "destroyed", was_salvaged: true}
      assert SortieCompletion.effective_damage_status(deployment) == "salvageable"
    end

    test "returns destroyed for destroyed but not salvaged units" do
      deployment = %{damage_status: "destroyed", was_salvaged: false}
      assert SortieCompletion.effective_damage_status(deployment) == "destroyed"
    end

    test "returns original status for non-destroyed units" do
      assert SortieCompletion.effective_damage_status(%{damage_status: "operational"}) == "operational"
      assert SortieCompletion.effective_damage_status(%{damage_status: "crippled"}) == "crippled"
      assert SortieCompletion.effective_damage_status(%{damage_status: "armor_damaged"}) == "armor_damaged"
    end
  end

  describe "costs_changed?/2" do
    test "returns true when operational costs differ" do
      sortie = %Sortie{total_expenses: 100, pilot_sp_cost: 20}
      # Old operational = 100 - 20 = 80, new = 100
      assert SortieCompletion.costs_changed?(sortie, 100) == true
    end

    test "returns false when operational costs are the same" do
      sortie = %Sortie{total_expenses: 100, pilot_sp_cost: 20}
      # Old operational = 100 - 20 = 80, new = 80
      assert SortieCompletion.costs_changed?(sortie, 80) == false
    end

    test "handles nil values" do
      sortie = %Sortie{total_expenses: nil, pilot_sp_cost: nil}
      assert SortieCompletion.costs_changed?(sortie, 0) == false
      assert SortieCompletion.costs_changed?(sortie, 50) == true
    end
  end

  describe "reverse_pilot_allocations/2" do
    test "returns empty list for nil allocations" do
      assert SortieCompletion.reverse_pilot_allocations(nil, []) == []
    end

    test "returns empty list for empty allocations" do
      assert SortieCompletion.reverse_pilot_allocations(%{}, []) == []
    end

    test "builds reversal changes for saved allocations" do
      pilot = %Pilot{
        id: 1,
        sp_allocated_to_skill: 400,
        sp_allocated_to_edge_tokens: 60,
        sp_allocated_to_edge_abilities: 0,
        edge_abilities: ["Accurate"],
        skill_level: 3,
        edge_tokens: 2
      }

      allocations = %{
        "1" => %{
          "baseline_skill" => 0,
          "baseline_tokens" => 0,
          "baseline_abilities" => 0,
          "baseline_edge_abilities" => [],
          "sp_to_spend" => 100
        }
      }

      reversals = SortieCompletion.reverse_pilot_allocations(allocations, [pilot])

      assert length(reversals) == 1
      {pilot_id, changes} = hd(reversals)
      assert pilot_id == 1
      assert changes.sp_allocated_to_skill == 0
      assert changes.sp_allocated_to_edge_tokens == 0
      assert changes.skill_level == 4  # Default skill from 0 SP
      assert changes.edge_tokens == 1  # Default 1 token from 0 SP
      assert changes.sp_available == 100
    end
  end

  describe "distribute_sp_to_pilots/3" do
    test "calculates total pilot SP cost" do
      pilots = [
        %Pilot{id: 1, sp_earned: 0, sp_available: 0, sorties_participated: 0, mvp_awards: 0},
        %Pilot{id: 2, sp_earned: 0, sp_available: 0, sorties_participated: 0, mvp_awards: 0}
      ]

      pilot_earnings = %{
        1 => %{sp: 100, status: :active, participated: true},
        2 => %{sp: 50, status: :active, participated: false}
      }

      result = SortieCompletion.distribute_sp_to_pilots(pilots, pilot_earnings, nil)

      assert result.total_pilot_sp_cost == 150
      assert length(result.pilot_changes) == 2
    end

    test "adds MVP bonus to selected pilot" do
      pilots = [
        %Pilot{id: 1, sp_earned: 0, sp_available: 0, sorties_participated: 0, mvp_awards: 0}
      ]

      pilot_earnings = %{
        1 => %{sp: 100, status: :active, participated: true}
      }

      result = SortieCompletion.distribute_sp_to_pilots(pilots, pilot_earnings, 1)

      {_id, changes} = Enum.find(result.pilot_changes, fn {id, _} -> id == 1 end)
      assert changes.sp_earned == 120  # 100 + 20 MVP bonus
      assert changes.sp_available == 120
      assert changes.mvp_awards == 1
    end

    test "does not include MVP bonus in total_pilot_sp_cost" do
      pilots = [
        %Pilot{id: 1, sp_earned: 0, sp_available: 0, sorties_participated: 0, mvp_awards: 0}
      ]

      pilot_earnings = %{
        1 => %{sp: 100, status: :active, participated: true}
      }

      result = SortieCompletion.distribute_sp_to_pilots(pilots, pilot_earnings, 1)

      # MVP bonus is free and should not be in total cost
      assert result.total_pilot_sp_cost == 100
    end
  end

  describe "build_casualty_updates/1" do
    test "returns status updates for wounded pilots" do
      deployments = [
        %Deployment{pilot_id: 1, pilot_casualty: "wounded"},
        %Deployment{pilot_id: 2, pilot_casualty: "none"}
      ]

      updates = SortieCompletion.build_casualty_updates(deployments)

      assert length(updates) == 1
      {pilot_id, changes} = hd(updates)
      assert pilot_id == 1
      assert changes.status == "wounded"
    end

    test "returns status updates for killed pilots" do
      deployments = [
        %Deployment{pilot_id: 1, pilot_casualty: "killed"}
      ]

      updates = SortieCompletion.build_casualty_updates(deployments)

      assert length(updates) == 1
      {pilot_id, changes} = hd(updates)
      assert pilot_id == 1
      assert changes.status == "deceased"
    end

    test "ignores deployments without pilots" do
      deployments = [
        %Deployment{pilot_id: nil, pilot_casualty: "killed"}
      ]

      updates = SortieCompletion.build_casualty_updates(deployments)

      assert updates == []
    end
  end

  describe "calculate_mvp_change/3" do
    test "returns nil changes when MVP doesn't change" do
      result = SortieCompletion.calculate_mvp_change(1, 1, [])
      assert result.old_mvp_changes == nil
      assert result.new_mvp_changes == nil
    end

    test "calculates changes when MVP is added" do
      pilots = [
        %Pilot{id: 1, sp_earned: 100, sp_available: 50, mvp_awards: 0}
      ]

      result = SortieCompletion.calculate_mvp_change(nil, 1, pilots)

      assert result.old_mvp_changes == nil
      assert result.new_mvp_changes.sp_earned == 120
      assert result.new_mvp_changes.sp_available == 70
      assert result.new_mvp_changes.mvp_awards == 1
    end

    test "calculates changes when MVP is removed" do
      pilots = [
        %Pilot{id: 1, sp_earned: 120, sp_available: 70, mvp_awards: 1}
      ]

      result = SortieCompletion.calculate_mvp_change(1, nil, pilots)

      assert result.old_mvp_changes.sp_earned == 100
      assert result.old_mvp_changes.sp_available == 50
      assert result.old_mvp_changes.mvp_awards == 0
      assert result.new_mvp_changes == nil
    end

    test "calculates changes when MVP switches" do
      pilots = [
        %Pilot{id: 1, sp_earned: 120, sp_available: 70, mvp_awards: 1},
        %Pilot{id: 2, sp_earned: 100, sp_available: 50, mvp_awards: 0}
      ]

      result = SortieCompletion.calculate_mvp_change(1, 2, pilots)

      assert result.old_mvp_changes.sp_earned == 100
      assert result.old_mvp_changes.mvp_awards == 0
      assert result.new_mvp_changes.sp_earned == 120
      assert result.new_mvp_changes.mvp_awards == 1
    end
  end

  describe "constants" do
    test "mvp_bonus_sp returns correct value" do
      assert SortieCompletion.mvp_bonus_sp() == 20
    end

    test "casualty_cost_sp returns correct value" do
      assert SortieCompletion.casualty_cost_sp() == 100
    end
  end
end
