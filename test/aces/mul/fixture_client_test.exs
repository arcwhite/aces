defmodule Aces.MUL.FixtureClientTest do
  use ExUnit.Case, async: false

  alias Aces.MUL.FixtureClient

  describe "fetch_units/1 with the default fixture set" do
    test "returns {:ok, {units, :fixture}} tagged as fixture-sourced" do
      assert {:ok, {units, :fixture}} = FixtureClient.fetch_units(%{})
      assert length(units) > 0
      assert Enum.all?(units, &is_map/1)
    end

    test "name filter matches by full_name substring, case-insensitively" do
      assert {:ok, {units, :fixture}} = FixtureClient.fetch_units(%{name: "atlas"})
      assert Enum.any?(units, &(&1.name == "Atlas"))
      refute Enum.any?(units, &(&1.name == "Locust"))
    end

    test "zero matches return an empty ok result, not an error" do
      assert {:ok, {[], :fixture}} =
               FixtureClient.fetch_units(%{name: "NonexistentUnitXYZ"})
    end

    test "types filter uses MUL type IDs and folds infantry into both subtypes" do
      assert {:ok, {mechs, :fixture}} = FixtureClient.fetch_units(%{types: [18]})
      assert Enum.all?(mechs, &(&1.unit_type == "battlemech"))

      assert {:ok, {vehicles, :fixture}} = FixtureClient.fetch_units(%{types: [19]})
      assert Enum.all?(vehicles, &(&1.unit_type == "combat_vehicle"))

      assert {:ok, {infantry, :fixture}} = FixtureClient.fetch_units(%{types: [21]})

      assert Enum.all?(
               infantry,
               &(&1.unit_type in ["battle_armor", "conventional_infantry"])
             )
    end

    test "unit_type string filter respects the battle_armor / infantry split" do
      assert {:ok, {ba, :fixture}} = FixtureClient.fetch_units(%{unit_type: "battle_armor"})
      assert Enum.all?(ba, &(&1.unit_type == "battle_armor"))

      assert {:ok, {ci, :fixture}} =
               FixtureClient.fetch_units(%{unit_type: "conventional_infantry"})

      assert Enum.all?(ci, &(&1.unit_type == "conventional_infantry"))
    end

    test "era + faction filter restricts to units listing that faction in that era" do
      assert {:ok, {units, :fixture}} =
               FixtureClient.fetch_units(%{eras: ["ilclan"], factions: ["clan_wolf"]})

      refute Enum.empty?(units)

      assert Enum.all?(units, fn unit ->
               "clan_wolf" in Map.get(unit.factions, "ilclan", [])
             end)
    end

    test "tonnage range filter" do
      assert {:ok, {units, :fixture}} =
               FixtureClient.fetch_units(%{min_tons: 70, max_tons: 100})

      assert Enum.all?(units, &(&1.tonnage >= 70 and &1.tonnage <= 100))
    end
  end

  describe "fetch_units/1 with a missing fixture file" do
    setup do
      original = Application.get_env(:aces, :mul_fixture_path)
      Application.put_env(:aces, :mul_fixture_path, "/tmp/does-not-exist-aces-mul-fixture.json")
      on_exit(fn -> Application.put_env(:aces, :mul_fixture_path, original) end)
    end

    test "returns a typed {:query_failed, ...} error instead of a silent []" do
      assert {:error, {:query_failed, {:fixture_load_failed, {:read_failed, :enoent}}}} =
               FixtureClient.fetch_units(%{})
    end
  end
end
