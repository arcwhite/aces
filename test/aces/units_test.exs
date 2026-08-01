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

    test "returns :no_alpha_strike_card when payload has neither bf_type nor point_value" do
      attrs = %{
        mul_id: 5150,
        name: "Stateless Row",
        variant: "SR-1",
        full_name: "Stateless Row SR-1",
        unit_type: "other"
      }

      assert {:error, :no_alpha_strike_card} = Units.create_or_update_master_unit(attrs)
      assert is_nil(Aces.Repo.get_by(Aces.Units.MasterUnit, mul_id: 5150))
    end

    test "accepts payloads that carry bf_type even without point_value" do
      attrs = %{
        mul_id: 5151,
        name: "BF-only Row",
        variant: "BFO-1",
        full_name: "BF-only Row BFO-1",
        unit_type: "battle_armor",
        bf_type: "BA"
      }

      assert {:ok, unit} = Units.create_or_update_master_unit(attrs)
      assert unit.bf_type == "BA"
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

  describe "translate_filters_for_api/1" do
    test "drops unknown opts silently instead of failing" do
      # An unknown opt used to leak into the API request; now it should just be
      # dropped (correctness comes from the local pass re-running).
      assert Units.translate_filters_for_api(foo: :bar) == %{}

      # A mix of known + unknown keeps the known ones.
      result = Units.translate_filters_for_api(unit_type: "battlemech", foo: :bar)
      assert result == %{types: [18]}
    end

    test "pair-completes a one-sided min_pv with a MaxPV sentinel" do
      # MUL ignores a lone MinPV / MaxPV; we must emit both.
      assert Units.translate_filters_for_api(min_pv: 20) == %{min_pv: 20, max_pv: 9999}
      assert Units.translate_filters_for_api(max_pv: 40) == %{min_pv: 0, max_pv: 40}
      assert Units.translate_filters_for_api(min_pv: 20, max_pv: 40) ==
               %{min_pv: 20, max_pv: 40}
    end

    test "translates tonnage_range and pair-completes a lone tonnage bound" do
      assert Units.translate_filters_for_api(tonnage_range: {50, 75}) ==
               %{min_tons: 50, max_tons: 75}
    end

    test "translates era_faction into eras + factions" do
      assert Units.translate_filters_for_api(era_faction: {["ilclan"], "mercenary"}) ==
               %{eras: ["ilclan"], factions: ["mercenary"]}
    end
  end

  describe "search_units/2 filter honouring" do
    test "min_pv is honoured in the returned local set" do
      _heavy = units_master_unit_fixture(
        name: "Filter Heavy",
        variant: "FH-1",
        full_name: "Filter Heavy FH-1",
        point_value: 50
      )

      light = units_master_unit_fixture(
        name: "Filter Light",
        variant: "FL-1",
        full_name: "Filter Light FL-1",
        point_value: 10
      )

      results = Units.search_units("Filter", min_pv: 40)
      assert Enum.all?(results, fn u -> u.point_value >= 40 end)
      refute Enum.any?(results, fn u -> u.id == light.id end)
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

  describe "list_cached_master_units/1" do
    test "returns {:ok, units} with all cached units ordered by name" do
      _bravo = units_master_unit_fixture(name: "Bravo", variant: "BR-1", full_name: "Bravo BR-1")
      _alpha = units_master_unit_fixture(name: "Alpha", variant: "AL-1", full_name: "Alpha AL-1")

      assert {:ok, units} = Units.list_cached_master_units()
      names = Enum.map(units, & &1.name)
      assert Enum.sort(names) == names
      assert "Alpha" in names
      assert "Bravo" in names
    end

    test "returns {:ok, []} when the cache is empty" do
      assert {:ok, []} = Units.list_cached_master_units()
    end

    test "honours the :limit opt without leaking it into the query filter" do
      for i <- 1..5 do
        units_master_unit_fixture(
          name: "Limit Test #{i}",
          variant: "LT-#{i}",
          full_name: "Limit Test LT-#{i}"
        )
      end

      assert {:ok, units} = Units.list_cached_master_units(limit: 3)
      assert length(units) == 3
    end

    test "passes through Filters keys such as :unit_type" do
      _mech = units_master_unit_fixture(
        name: "Cached Mech",
        variant: "CM-1",
        full_name: "Cached Mech CM-1",
        unit_type: "battlemech"
      )

      _vehicle = combat_vehicle_fixture(
        name: "Cached Vehicle",
        variant: "CV-1",
        full_name: "Cached Vehicle CV-1"
      )

      assert {:ok, units} = Units.list_cached_master_units(unit_type: "battlemech")
      assert Enum.all?(units, fn u -> u.unit_type == "battlemech" end)
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
