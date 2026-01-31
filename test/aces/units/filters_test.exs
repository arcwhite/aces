defmodule Aces.Units.FiltersTest do
  use Aces.DataCase

  alias Aces.Units.Filters
  alias Aces.Units.MasterUnit

  describe "filter/2" do
    test "returns unmodified query when filters list is empty" do
      query = MasterUnit

      # Empty filters should return the same query
      result = Filters.filter(query, [])
      assert result == query
    end

    test "filters by unit_type" do
      mech = master_unit_fixture(%{unit_type: "BattleMech", name: "Atlas"})
      _vehicle = master_unit_fixture(%{unit_type: "Combat Vehicle", name: "Goblin"})

      results =
        MasterUnit
        |> Filters.filter(unit_type: "BattleMech")
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).id == mech.id
    end

    test "filters by min_pv" do
      heavy = master_unit_fixture(%{point_value: 50, name: "Heavy"})
      _light = master_unit_fixture(%{point_value: 20, name: "Light"})

      results =
        MasterUnit
        |> Filters.filter(min_pv: 40)
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).id == heavy.id
    end

    test "filters by max_pv" do
      _heavy = master_unit_fixture(%{point_value: 50, name: "Heavy"})
      light = master_unit_fixture(%{point_value: 20, name: "Light"})

      results =
        MasterUnit
        |> Filters.filter(max_pv: 30)
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).id == light.id
    end

    test "filters by tonnage_range" do
      heavy = master_unit_fixture(%{tonnage: 80, name: "Assault"})
      medium = master_unit_fixture(%{tonnage: 50, name: "Medium"})
      _light = master_unit_fixture(%{tonnage: 20, name: "Light"})

      results =
        MasterUnit
        |> Filters.filter(tonnage_range: {40, 90})
        |> Repo.all()

      result_ids = Enum.map(results, & &1.id)
      assert heavy.id in result_ids
      assert medium.id in result_ids
      assert length(results) == 2
    end

    test "filters by era" do
      ilclan = master_unit_fixture(%{era_id: 257, name: "IlClan Unit"})
      _jihad = master_unit_fixture(%{era_id: 14, name: "Jihad Unit"})

      results =
        MasterUnit
        |> Filters.filter(era: "ilclan")
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).id == ilclan.id
    end

    test "ignores unknown era strings" do
      unit = master_unit_fixture(%{name: "Test Unit"})

      results =
        MasterUnit
        |> Filters.filter(era: "fake_era")
        |> Repo.all()

      # Should not filter anything when era is unknown
      assert length(results) >= 1
      assert unit.id in Enum.map(results, & &1.id)
    end

    test "filters by faction (era-based format)" do
      merc = master_unit_fixture(%{
        name: "Merc Unit",
        factions: %{"ilclan" => ["mercenary"]}
      })
      _clan = master_unit_fixture(%{
        name: "Clan Unit",
        factions: %{"ilclan" => ["clan_wolf"]}
      })

      results =
        MasterUnit
        |> Filters.filter(faction: "mercenary")
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).id == merc.id
    end

    test "filters by era_faction" do
      ilclan_merc = master_unit_fixture(%{
        name: "IlClan Merc",
        factions: %{"ilclan" => ["mercenary"], "dark_age" => ["clan_wolf"]}
      })
      _dark_age_only = master_unit_fixture(%{
        name: "Dark Age Only",
        factions: %{"dark_age" => ["mercenary"]}
      })

      # Filter for mercenary in ilclan era only
      results =
        MasterUnit
        |> Filters.filter(era_faction: {["ilclan"], "mercenary"})
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).id == ilclan_merc.id
    end

    test "filters by multiple eras in era_faction" do
      ilclan_merc = master_unit_fixture(%{
        name: "IlClan Merc",
        factions: %{"ilclan" => ["mercenary"]}
      })
      dark_age_merc = master_unit_fixture(%{
        name: "Dark Age Merc",
        factions: %{"dark_age" => ["mercenary"]}
      })
      _jihad_only = master_unit_fixture(%{
        name: "Jihad Only",
        factions: %{"jihad" => ["mercenary"]}
      })

      # Filter for mercenary in ilclan OR dark_age
      results =
        MasterUnit
        |> Filters.filter(era_faction: {["ilclan", "dark_age"], "mercenary"})
        |> Repo.all()

      result_ids = Enum.map(results, & &1.id)
      assert ilclan_merc.id in result_ids
      assert dark_age_merc.id in result_ids
      assert length(results) == 2
    end

    test "combines multiple filters" do
      matching = master_unit_fixture(%{
        name: "Perfect Match",
        unit_type: "BattleMech",
        point_value: 35,
        factions: %{"ilclan" => ["mercenary"]}
      })
      _wrong_type = master_unit_fixture(%{
        name: "Wrong Type",
        unit_type: "Combat Vehicle",
        point_value: 35,
        factions: %{"ilclan" => ["mercenary"]}
      })
      _wrong_pv = master_unit_fixture(%{
        name: "Wrong PV",
        unit_type: "BattleMech",
        point_value: 80,
        factions: %{"ilclan" => ["mercenary"]}
      })

      results =
        MasterUnit
        |> Filters.filter(unit_type: "BattleMech", min_pv: 30, max_pv: 40)
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).id == matching.id
    end

    test "ignores unknown filter keys" do
      unit = master_unit_fixture(%{name: "Test Unit"})

      # Unknown filters should be silently ignored
      results =
        MasterUnit
        |> Filters.filter(unknown_filter: "value", another_unknown: 123)
        |> Repo.all()

      assert unit.id in Enum.map(results, & &1.id)
    end
  end
end
