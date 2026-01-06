defmodule Aces.UnitsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Aces.Units` context.
  """

  alias Aces.Units

  def units_master_unit_fixture(attrs \\ %{}) do
    {:ok, master_unit} =
      attrs
      |> Enum.into(%{
        mul_id: System.unique_integer([:positive]),
        name: "Test BattleMech",
        variant: "TMB-1",
        full_name: "Test BattleMech TMB-1", 
        unit_type: "battlemech",
        tonnage: 75,
        point_value: 32,
        battle_value: 1234,
        technology_base: "Inner Sphere",
        rules_level: "Standard",
        role: "Brawler",
        cost: 5_000_000,
        date_introduced: 3050,
        era_id: 14,
        bf_move: "6\"",
        bf_armor: 6,
        bf_structure: 3,
        bf_damage_short: "3",
        bf_damage_medium: "3", 
        bf_damage_long: "1",
        bf_overheat: 1,
        bf_abilities: "AC1/1/1",
        image_url: "/Unit/QuickImage/123",
        is_published: true,
        last_synced_at: DateTime.utc_now()
      })
      |> Units.create_or_update_master_unit()

    master_unit
  end

  def atlas_master_unit_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      mul_id: 39,
      name: "Atlas",
      variant: "AS7-D",
      full_name: "Atlas AS7-D",
      unit_type: "battlemech",
      tonnage: 100,
      point_value: 48,
      battle_value: 1897
    })
    |> units_master_unit_fixture()
  end

  def light_mech_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      name: "Locust", 
      variant: "LCT-1V",
      full_name: "Locust LCT-1V",
      tonnage: 20,
      point_value: 8
    })
    |> units_master_unit_fixture()
  end

  def combat_vehicle_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      name: "Demolisher",
      variant: "DMO-1V", 
      full_name: "Demolisher DMO-1V",
      unit_type: "combat_vehicle",
      tonnage: 80,
      point_value: 36
    })
    |> units_master_unit_fixture()
  end
end