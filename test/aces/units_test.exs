defmodule Aces.UnitsTest do
  use Aces.DataCase

  alias Aces.Units

  import Aces.UnitsFixtures

  describe "search_units_for_company/2" do
    test "returns ok with results when search term is valid" do
      # Create a master unit that matches the search
      _atlas = atlas_master_unit_fixture()

      assert {:ok, results} = Units.search_units_for_company("Atlas", %{})
      assert length(results) > 0
      assert Enum.any?(results, fn unit -> unit.name == "Atlas" end)
    end

    test "returns error when search term is too short" do
      assert {:error, :term_too_short} = Units.search_units_for_company("A", %{})
    end

    test "returns error when search term is empty" do
      assert {:error, :term_too_short} = Units.search_units_for_company("", %{})
    end

    test "trims whitespace from search term" do
      _atlas = atlas_master_unit_fixture()

      assert {:error, :term_too_short} = Units.search_units_for_company("  A  ", %{})
      assert {:ok, _results} = Units.search_units_for_company("  Atlas  ", %{})
    end

    test "filters by unit type when type filter is provided" do
      # Create units of different types
      _mech = units_master_unit_fixture(
        name: "Test Mech",
        variant: "TM-1",
        full_name: "Test Mech TM-1",
        unit_type: "battlemech"
      )

      _vehicle = combat_vehicle_fixture(
        name: "Test Vehicle",
        variant: "TV-1",
        full_name: "Test Vehicle TV-1"
      )

      # Search for battlemechs only
      assert {:ok, results} = Units.search_units_for_company("Test", %{type: "battlemech"})
      assert Enum.all?(results, fn unit -> unit.unit_type == "battlemech" end)
    end

    test "filters by era and faction when both are provided" do
      # Create a unit with specific faction availability
      _unit = units_master_unit_fixture(
        name: "Mercenary Mech",
        variant: "MM-1",
        full_name: "Mercenary Mech MM-1",
        factions: %{
          "ilclan" => ["mercenary", "clan_wolf"],
          "dark_age" => ["mercenary"]
        }
      )

      # Search with era/faction filter
      filters = %{
        eras: ["ilclan", "dark_age"],
        faction: "mercenary"
      }

      assert {:ok, results} = Units.search_units_for_company("Mercenary", filters)
      assert length(results) > 0
    end

    test "combines multiple filters correctly" do
      # Create units with different characteristics
      _mech1 = units_master_unit_fixture(
        name: "Combined Filter Mech",
        variant: "CFM-1",
        full_name: "Combined Filter Mech CFM-1",
        unit_type: "battlemech",
        factions: %{"ilclan" => ["mercenary"]}
      )

      _vehicle1 = combat_vehicle_fixture(
        name: "Combined Filter Vehicle",
        variant: "CFV-1",
        full_name: "Combined Filter Vehicle CFV-1",
        factions: %{"ilclan" => ["mercenary"]}
      )

      # Filter for battlemechs only with era/faction
      filters = %{
        type: "battlemech",
        eras: ["ilclan"],
        faction: "mercenary"
      }

      assert {:ok, results} = Units.search_units_for_company("Combined Filter", filters)
      assert Enum.all?(results, fn unit -> unit.unit_type == "battlemech" end)
    end

    test "returns empty list when no units match search term" do
      assert {:ok, results} = Units.search_units_for_company("NonexistentUnit12345", %{})
      assert results == []
    end

    test "returns empty list when filters exclude all units" do
      _mech = units_master_unit_fixture(
        name: "Filter Test",
        variant: "FT-1",
        full_name: "Filter Test FT-1",
        unit_type: "battlemech"
      )

      # Filter for combat_vehicle when only battlemech exists
      assert {:ok, results} = Units.search_units_for_company("Filter Test", %{type: "combat_vehicle"})
      assert results == []
    end

    test "handles nil values in filter map gracefully" do
      _atlas = atlas_master_unit_fixture()

      filters = %{
        type: nil,
        eras: nil,
        faction: nil
      }

      assert {:ok, results} = Units.search_units_for_company("Atlas", filters)
      assert length(results) > 0
    end

    test "handles empty list for eras filter gracefully" do
      _atlas = atlas_master_unit_fixture()

      filters = %{
        eras: [],
        faction: "mercenary"
      }

      # Empty eras list means era_faction filter is not applied
      assert {:ok, results} = Units.search_units_for_company("Atlas", filters)
      assert length(results) > 0
    end

    test "handles missing faction when eras are provided" do
      _atlas = atlas_master_unit_fixture()

      filters = %{
        eras: ["ilclan", "dark_age"],
        faction: nil
      }

      # Missing faction means era_faction filter is not applied
      assert {:ok, results} = Units.search_units_for_company("Atlas", filters)
      assert length(results) > 0
    end

    test "case-insensitive search for unit names" do
      _atlas = atlas_master_unit_fixture()

      # Search with different case variations
      assert {:ok, results1} = Units.search_units_for_company("atlas", %{})
      assert {:ok, results2} = Units.search_units_for_company("ATLAS", %{})
      assert {:ok, results3} = Units.search_units_for_company("Atlas", %{})

      assert length(results1) > 0
      assert length(results2) > 0
      assert length(results3) > 0
    end

    test "searches by variant as well as name" do
      _atlas = atlas_master_unit_fixture(variant: "AS7-D")

      # Search by variant code
      assert {:ok, results} = Units.search_units_for_company("AS7", %{})
      assert length(results) > 0
      assert Enum.any?(results, fn unit -> unit.variant =~ "AS7" end)
    end

    test "limits results to prevent overwhelming response" do
      # Create many units with similar names
      for i <- 1..60 do
        units_master_unit_fixture(
          name: "Mass Unit",
          variant: "MU-#{i}",
          full_name: "Mass Unit MU-#{i}"
        )
      end

      assert {:ok, results} = Units.search_units_for_company("Mass", %{})
      # The implementation limits to 50 results
      assert length(results) <= 50
    end
  end

  describe "search_units/2" do
    test "returns empty list when search term is too short" do
      results = Units.search_units("A")
      assert results == []
    end

    test "returns cached units when available" do
      atlas = atlas_master_unit_fixture()

      results = Units.search_units("Atlas")
      assert length(results) > 0
      assert Enum.any?(results, fn unit -> unit.id == atlas.id end)
    end
  end

  describe "get_master_unit_by_mul_id/1" do
    test "returns ok with unit when unit exists in cache" do
      unit = atlas_master_unit_fixture(mul_id: 123)

      assert {:ok, fetched_unit} = Units.get_master_unit_by_mul_id(123)
      assert fetched_unit.id == unit.id
      assert fetched_unit.mul_id == 123
    end

    test "returns error when unit not in cache and cannot be fetched" do
      # Non-existent MUL ID
      assert {:error, :not_found} = Units.get_master_unit_by_mul_id(999_999)
    end
  end

  describe "create_or_update_master_unit/1" do
    test "creates a new master unit" do
      attrs = %{
        mul_id: 456,
        name: "New Unit",
        variant: "NU-1",
        full_name: "New Unit NU-1",
        unit_type: "battlemech",
        point_value: 30,
        last_synced_at: DateTime.truncate(DateTime.utc_now(), :second)
      }

      assert {:ok, unit} = Units.create_or_update_master_unit(attrs)
      assert unit.mul_id == 456
      assert unit.name == "New Unit"
    end

    test "updates existing master unit" do
      existing = atlas_master_unit_fixture(mul_id: 789, point_value: 40)

      attrs = %{
        mul_id: 789,
        name: "Atlas",
        variant: "AS7-K",
        point_value: 50
      }

      assert {:ok, updated} = Units.create_or_update_master_unit(attrs)
      assert updated.id == existing.id
      assert updated.point_value == 50
      assert updated.variant == "AS7-K"
    end

    test "merges faction data when updating" do
      existing = units_master_unit_fixture(
        mul_id: 999,
        factions: %{"ilclan" => ["mercenary"]}
      )

      # Update with additional faction data
      attrs = %{
        mul_id: 999,
        name: existing.name,
        variant: existing.variant,
        factions: %{"dark_age" => ["clan_wolf"]}
      }

      assert {:ok, updated} = Units.create_or_update_master_unit(attrs)

      # Both faction entries should be present
      assert Map.has_key?(updated.factions, "ilclan")
      assert Map.has_key?(updated.factions, "dark_age")
      assert "mercenary" in updated.factions["ilclan"]
      assert "clan_wolf" in updated.factions["dark_age"]
    end
  end

  describe "list_variants_for_chassis/1" do
    test "returns all variants of a chassis by name" do
      _variant1 = units_master_unit_fixture(name: "Warhammer", variant: "WHM-6R")
      _variant2 = units_master_unit_fixture(name: "Warhammer", variant: "WHM-6D")
      _variant3 = units_master_unit_fixture(name: "Warhammer", variant: "WHM-7M")
      _other = atlas_master_unit_fixture()

      variants = Units.list_variants_for_chassis("Warhammer")

      assert length(variants) == 3
      assert Enum.all?(variants, fn v -> v.name == "Warhammer" end)
    end

    test "returns all variants of a chassis by MasterUnit struct" do
      unit = units_master_unit_fixture(name: "Mad Cat", variant: "Prime")
      _variant2 = units_master_unit_fixture(name: "Mad Cat", variant: "A")

      variants = Units.list_variants_for_chassis(unit)

      assert length(variants) == 2
      assert Enum.all?(variants, fn v -> v.name == "Mad Cat" end)
    end

    test "returns empty list when chassis has no variants" do
      variants = Units.list_variants_for_chassis("NonexistentChassis")
      assert variants == []
    end
  end

  describe "is_omni?/1" do
    test "returns true when unit has OMNI ability" do
      omni = omni_mech_fixture()
      assert Units.is_omni?(omni) == true
    end

    test "returns false when unit has no OMNI ability" do
      regular = atlas_master_unit_fixture(bf_abilities: "CASE, AC1/1/1")
      assert Units.is_omni?(regular) == false
    end

    test "returns false when bf_abilities is nil" do
      unit = atlas_master_unit_fixture(bf_abilities: nil)
      assert Units.is_omni?(unit) == false
    end

    test "returns false when bf_abilities is empty string" do
      unit = atlas_master_unit_fixture(bf_abilities: "")
      assert Units.is_omni?(unit) == false
    end
  end

  describe "count_cached_units/0" do
    test "returns correct count of cached units" do
      initial_count = Units.count_cached_units()

      _unit1 = atlas_master_unit_fixture()
      _unit2 = light_mech_fixture()

      new_count = Units.count_cached_units()
      assert new_count == initial_count + 2
    end
  end
end
