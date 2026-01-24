defmodule Aces.Campaigns.PilotAllocationTest do
  use Aces.DataCase

  alias Aces.Campaigns.PilotAllocation
  alias Aces.Companies.Pilot

  describe "build_fresh/1" do
    test "creates allocation with baseline values from pilot" do
      pilot = %Pilot{
        id: 1,
        sp_allocated_to_skill: 400,
        sp_allocated_to_edge_tokens: 60,
        sp_allocated_to_edge_abilities: 60,
        edge_abilities: ["Accurate"],
        skill_level: 3,
        edge_tokens: 2,
        sp_available: 100
      }

      allocation = PilotAllocation.build_fresh(pilot)

      assert allocation.pilot == pilot
      assert allocation.baseline_skill == 400
      assert allocation.baseline_tokens == 60
      assert allocation.baseline_abilities == 60
      assert allocation.baseline_edge_abilities == ["Accurate"]
      assert allocation.add_skill == 0
      assert allocation.add_tokens == 0
      assert allocation.add_abilities == 0
      assert allocation.new_edge_abilities == []
      assert allocation.sp_to_spend == 100
      assert allocation.sp_remaining == 100
      assert allocation.skill_level == 3
      assert allocation.edge_tokens == 2
      assert allocation.has_error == false
    end

    test "handles pilot with nil edge_abilities" do
      pilot = %Pilot{
        id: 1,
        sp_allocated_to_skill: 0,
        sp_allocated_to_edge_tokens: 0,
        sp_allocated_to_edge_abilities: 0,
        edge_abilities: nil,
        skill_level: 4,
        edge_tokens: 1,
        sp_available: 150
      }

      allocation = PilotAllocation.build_fresh(pilot)

      assert allocation.baseline_edge_abilities == []
    end
  end

  describe "build_from_saved/2" do
    test "restores allocation from saved data" do
      pilot = %Pilot{
        id: 1,
        sp_allocated_to_skill: 500,
        sp_allocated_to_edge_tokens: 120,
        sp_allocated_to_edge_abilities: 0,
        edge_abilities: ["Accurate", "Dodge"],
        skill_level: 3,
        edge_tokens: 3,
        sp_available: 0
      }

      saved = %{
        "baseline_skill" => 400,
        "baseline_tokens" => 60,
        "baseline_abilities" => 0,
        "baseline_edge_abilities" => ["Accurate"],
        "add_skill" => 100,
        "add_tokens" => 60,
        "add_abilities" => 0,
        "new_edge_abilities" => ["Dodge"],
        "sp_to_spend" => 160
      }

      allocation = PilotAllocation.build_from_saved(pilot, saved)

      assert allocation.baseline_skill == 400
      assert allocation.baseline_tokens == 60
      assert allocation.baseline_abilities == 0
      assert allocation.baseline_edge_abilities == ["Accurate"]
      assert allocation.add_skill == 100
      assert allocation.add_tokens == 60
      assert allocation.add_abilities == 0
      assert allocation.new_edge_abilities == ["Dodge"]
      assert allocation.sp_to_spend == 160
      assert allocation.sp_remaining == 0  # 160 - 100 - 60 - 0
      assert allocation.skill_level == 3  # From 500 total skill SP (400 + 100), threshold for skill 2 is 900
      assert allocation.edge_tokens == 3  # From 120 total token SP
      assert allocation.has_error == false
    end

    test "calculates error when overspent" do
      pilot = %Pilot{id: 1}

      saved = %{
        "baseline_skill" => 0,
        "baseline_tokens" => 0,
        "baseline_abilities" => 0,
        "baseline_edge_abilities" => [],
        "add_skill" => 100,
        "add_tokens" => 50,
        "add_abilities" => 0,
        "new_edge_abilities" => [],
        "sp_to_spend" => 100  # Less than add_skill + add_tokens
      }

      allocation = PilotAllocation.build_from_saved(pilot, saved)

      assert allocation.sp_remaining == -50
      assert allocation.has_error == true
    end
  end

  describe "build_all/2" do
    test "returns pilots with SP and their allocations" do
      pilot1 = %Pilot{
        id: 1,
        sp_allocated_to_skill: 0,
        sp_allocated_to_edge_tokens: 0,
        sp_allocated_to_edge_abilities: 0,
        edge_abilities: [],
        skill_level: 4,
        edge_tokens: 1,
        sp_available: 100
      }

      pilot2 = %Pilot{
        id: 2,
        sp_allocated_to_skill: 0,
        sp_allocated_to_edge_tokens: 0,
        sp_allocated_to_edge_abilities: 0,
        edge_abilities: [],
        skill_level: 4,
        edge_tokens: 1,
        sp_available: 0  # No SP to spend
      }

      {pilots_with_sp, allocations} = PilotAllocation.build_all([pilot1, pilot2], nil)

      assert length(pilots_with_sp) == 1
      assert hd(pilots_with_sp).id == 1
      assert Map.has_key?(allocations, 1)
      refute Map.has_key?(allocations, 2)
    end

    test "includes pilots with saved allocations even if they have no SP" do
      pilot = %Pilot{
        id: 1,
        sp_allocated_to_skill: 100,
        sp_allocated_to_edge_tokens: 0,
        sp_allocated_to_edge_abilities: 0,
        edge_abilities: [],
        skill_level: 4,
        edge_tokens: 1,
        sp_available: 0
      }

      saved_allocations = %{
        "1" => %{
          "baseline_skill" => 0,
          "baseline_tokens" => 0,
          "baseline_abilities" => 0,
          "baseline_edge_abilities" => [],
          "add_skill" => 100,
          "add_tokens" => 0,
          "add_abilities" => 0,
          "new_edge_abilities" => [],
          "sp_to_spend" => 100
        }
      }

      {pilots_with_sp, allocations} = PilotAllocation.build_all([pilot], saved_allocations)

      assert length(pilots_with_sp) == 1
      assert Map.has_key?(allocations, 1)
      assert allocations[1].add_skill == 100
    end
  end

  describe "update_allocation/3" do
    setup do
      pilot = %Pilot{
        id: 1,
        sp_allocated_to_skill: 0,
        sp_allocated_to_edge_tokens: 0,
        sp_allocated_to_edge_abilities: 0,
        edge_abilities: [],
        skill_level: 4,
        edge_tokens: 1,
        sp_available: 500
      }

      allocation = PilotAllocation.build_fresh(pilot)
      %{allocation: allocation}
    end

    test "updates skill allocation", %{allocation: allocation} do
      updated = PilotAllocation.update_allocation(allocation, "skill", 400)

      assert updated.add_skill == 400
      assert updated.sp_remaining == 100  # 500 - 400
      assert updated.skill_level == 3  # 400 SP = skill 3
    end

    test "updates edge tokens allocation", %{allocation: allocation} do
      updated = PilotAllocation.update_allocation(allocation, "edge_tokens", 200)

      assert updated.add_tokens == 200
      assert updated.sp_remaining == 300  # 500 - 200
      assert updated.edge_tokens == 4  # 200 SP = 4 tokens
    end

    test "updates edge abilities allocation", %{allocation: allocation} do
      updated = PilotAllocation.update_allocation(allocation, "edge_abilities", 180)

      assert updated.add_abilities == 180
      assert updated.sp_remaining == 320  # 500 - 180
      assert updated.max_abilities == 2  # 180 SP = 2 abilities
    end

    test "sets error when overspending", %{allocation: allocation} do
      updated = PilotAllocation.update_allocation(allocation, "skill", 600)

      assert updated.add_skill == 600
      assert updated.sp_remaining == -100
      assert updated.has_error == true
    end

    test "clamps negative values to zero", %{allocation: allocation} do
      updated = PilotAllocation.update_allocation(allocation, "skill", -100)

      assert updated.add_skill == 0
    end

    test "trims edge abilities when max is reduced" do
      pilot = %Pilot{
        id: 1,
        sp_allocated_to_skill: 0,
        sp_allocated_to_edge_tokens: 0,
        sp_allocated_to_edge_abilities: 0,
        edge_abilities: [],
        skill_level: 4,
        edge_tokens: 1,
        sp_available: 500
      }

      # Build allocation and add abilities
      allocation = PilotAllocation.build_fresh(pilot)
      allocation = PilotAllocation.update_allocation(allocation, "edge_abilities", 360)  # 3 abilities
      allocation = PilotAllocation.toggle_edge_ability(allocation, "Accurate")
      allocation = PilotAllocation.toggle_edge_ability(allocation, "Dodge")

      assert length(allocation.new_edge_abilities) == 2

      # Reduce abilities allocation
      updated = PilotAllocation.update_allocation(allocation, "edge_abilities", 60)  # Only 1 ability

      assert updated.max_abilities == 1
      assert length(updated.new_edge_abilities) == 1
    end

    test "ignores unknown fields", %{allocation: allocation} do
      updated = PilotAllocation.update_allocation(allocation, "unknown", 100)

      assert updated.add_skill == 0
      assert updated.add_tokens == 0
      assert updated.add_abilities == 0
    end
  end

  describe "toggle_edge_ability/2" do
    setup do
      pilot = %Pilot{
        id: 1,
        sp_allocated_to_skill: 0,
        sp_allocated_to_edge_tokens: 0,
        sp_allocated_to_edge_abilities: 180,  # 2 abilities
        edge_abilities: ["Accurate"],  # 1 baseline ability
        skill_level: 4,
        edge_tokens: 1,
        sp_available: 200
      }

      allocation = PilotAllocation.build_fresh(pilot)
      %{allocation: allocation}
    end

    test "adds new ability", %{allocation: allocation} do
      updated = PilotAllocation.toggle_edge_ability(allocation, "Dodge")

      assert "Dodge" in updated.new_edge_abilities
    end

    test "removes new ability", %{allocation: allocation} do
      allocation = %{allocation | new_edge_abilities: ["Dodge"]}
      updated = PilotAllocation.toggle_edge_ability(allocation, "Dodge")

      refute "Dodge" in updated.new_edge_abilities
    end

    test "cannot remove baseline ability", %{allocation: allocation} do
      updated = PilotAllocation.toggle_edge_ability(allocation, "Accurate")

      # Accurate is still in baseline, not added to new
      assert "Accurate" in updated.baseline_edge_abilities
      refute "Accurate" in updated.new_edge_abilities
    end

    test "cannot add more than max abilities", %{allocation: allocation} do
      # Max is 2, baseline has 1, so we can add 1 more
      allocation = PilotAllocation.toggle_edge_ability(allocation, "Dodge")
      assert length(allocation.new_edge_abilities) == 1

      # Try to add a second - should not be added (at max)
      updated = PilotAllocation.toggle_edge_ability(allocation, "Evasive")
      assert length(updated.new_edge_abilities) == 1
      refute "Evasive" in updated.new_edge_abilities
    end
  end

  describe "validate/1" do
    test "returns :ok when allocation is complete" do
      allocation = %{sp_remaining: 0, has_error: false}
      assert PilotAllocation.validate(allocation) == :ok
    end

    test "returns error when overspent" do
      allocation = %{sp_remaining: -10, has_error: true}
      assert PilotAllocation.validate(allocation) == {:error, :overspent}
    end

    test "returns error when SP not fully spent" do
      allocation = %{sp_remaining: 50, has_error: false}
      assert PilotAllocation.validate(allocation) == {:error, :sp_not_fully_spent}
    end
  end

  describe "all_valid?/1" do
    test "returns true when all allocations are valid" do
      allocations = %{
        1 => %{sp_remaining: 0, has_error: false},
        2 => %{sp_remaining: 0, has_error: false}
      }

      assert PilotAllocation.all_valid?(allocations)
    end

    test "returns false when any allocation has remaining SP" do
      allocations = %{
        1 => %{sp_remaining: 0, has_error: false},
        2 => %{sp_remaining: 10, has_error: false}
      }

      refute PilotAllocation.all_valid?(allocations)
    end

    test "returns false when any allocation has error" do
      allocations = %{
        1 => %{sp_remaining: 0, has_error: true},
        2 => %{sp_remaining: 0, has_error: false}
      }

      refute PilotAllocation.all_valid?(allocations)
    end

    test "returns true for empty map" do
      assert PilotAllocation.all_valid?(%{})
    end
  end

  describe "any_errors?/1" do
    test "returns false when no errors" do
      allocations = %{
        1 => %{has_error: false},
        2 => %{has_error: false}
      }

      refute PilotAllocation.any_errors?(allocations)
    end

    test "returns true when any has error" do
      allocations = %{
        1 => %{has_error: false},
        2 => %{has_error: true}
      }

      assert PilotAllocation.any_errors?(allocations)
    end
  end

  describe "to_saved_format/1" do
    test "converts allocation to saveable map" do
      allocation = %{
        baseline_skill: 400,
        baseline_tokens: 60,
        baseline_abilities: 60,
        baseline_edge_abilities: ["Accurate"],
        add_skill: 100,
        add_tokens: 60,
        add_abilities: 60,
        new_edge_abilities: ["Dodge"],
        sp_to_spend: 220
      }

      saved = PilotAllocation.to_saved_format(allocation)

      assert saved["baseline_skill"] == 400
      assert saved["baseline_tokens"] == 60
      assert saved["baseline_abilities"] == 60
      assert saved["baseline_edge_abilities"] == ["Accurate"]
      assert saved["add_skill"] == 100
      assert saved["add_tokens"] == 60
      assert saved["add_abilities"] == 60
      assert saved["new_edge_abilities"] == ["Dodge"]
      assert saved["sp_to_spend"] == 220
    end
  end

  describe "all_to_saved_format/1" do
    test "converts all allocations to map with string keys" do
      allocations = %{
        1 => %{
          baseline_skill: 0,
          baseline_tokens: 0,
          baseline_abilities: 0,
          baseline_edge_abilities: [],
          add_skill: 100,
          add_tokens: 0,
          add_abilities: 0,
          new_edge_abilities: [],
          sp_to_spend: 100
        },
        2 => %{
          baseline_skill: 0,
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

      saved = PilotAllocation.all_to_saved_format(allocations)

      assert Map.has_key?(saved, "1")
      assert Map.has_key?(saved, "2")
      assert saved["1"]["add_skill"] == 100
      assert saved["2"]["add_skill"] == 50
    end
  end

  describe "to_pilot_changes/1" do
    test "calculates pilot changes from allocation" do
      allocation = %{
        baseline_skill: 400,
        baseline_tokens: 60,
        baseline_abilities: 60,
        baseline_edge_abilities: ["Accurate"],
        add_skill: 500,
        add_tokens: 60,
        add_abilities: 120,
        new_edge_abilities: ["Dodge", "Evasive"]
      }

      changes = PilotAllocation.to_pilot_changes(allocation)

      assert changes.sp_allocated_to_skill == 900  # 400 + 500
      assert changes.sp_allocated_to_edge_tokens == 120  # 60 + 60
      assert changes.sp_allocated_to_edge_abilities == 180  # 60 + 120
      assert changes.edge_abilities == ["Accurate", "Dodge", "Evasive"]
      assert changes.skill_level == 2  # 900 SP = skill 2
      assert changes.edge_tokens == 3  # 120 SP = 3 tokens
      assert changes.sp_available == 0
    end
  end

  describe "total_abilities_count/1" do
    test "returns sum of baseline and new abilities" do
      allocation = %{
        baseline_edge_abilities: ["Accurate", "Dodge"],
        new_edge_abilities: ["Evasive"]
      }

      assert PilotAllocation.total_abilities_count(allocation) == 3
    end

    test "returns 0 for empty abilities" do
      allocation = %{
        baseline_edge_abilities: [],
        new_edge_abilities: []
      }

      assert PilotAllocation.total_abilities_count(allocation) == 0
    end
  end
end
