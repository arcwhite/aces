defmodule Aces.MUL.ClientTest do
  use ExUnit.Case, async: true

  alias Aces.MUL.Client

  describe "normalize_unit/1 unit_type resolution" do
    test "infantry payload with BFType \"CI\" becomes conventional_infantry" do
      unit =
        Client.normalize_unit(%{
          "Id" => 1143,
          "Name" => "Foot Platoon (Flamer)",
          "Type" => %{"Id" => 21, "Name" => "Infantry"},
          "BFType" => "CI"
        })

      assert unit.unit_type == "conventional_infantry"
      assert unit.bf_type == "CI"
    end

    test "infantry payload with BFType \"BA\" becomes battle_armor" do
      unit =
        Client.normalize_unit(%{
          "Id" => 1279,
          "Name" => "Gray Death Standard Suit [MG]",
          "Type" => %{"Id" => 21, "Name" => "Infantry"},
          "BFType" => "BA"
        })

      assert unit.unit_type == "battle_armor"
      assert unit.bf_type == "BA"
    end

    test "BFType matching is case-insensitive" do
      assert Client.normalize_unit(%{
               "Id" => 1,
               "Name" => "Lower-case CI",
               "Type" => %{"Id" => 21},
               "BFType" => "ci"
             }).unit_type == "conventional_infantry"

      assert Client.normalize_unit(%{
               "Id" => 2,
               "Name" => "Lower-case BA",
               "Type" => %{"Id" => 21},
               "BFType" => "ba"
             }).unit_type == "battle_armor"
    end

    test "infantry payload with missing/unknown BFType defaults to battle_armor" do
      assert Client.normalize_unit(%{
               "Id" => 3,
               "Name" => "No BFType",
               "Type" => %{"Id" => 21}
             }).unit_type == "battle_armor"

      assert Client.normalize_unit(%{
               "Id" => 4,
               "Name" => "Odd BFType",
               "Type" => %{"Id" => 21},
               "BFType" => "???"
             }).unit_type == "battle_armor"
    end

    test "infantry resolved by type Name when no Id is present" do
      assert Client.normalize_unit(%{
               "Id" => 5,
               "Name" => "Name-only Infantry",
               "Type" => %{"Name" => "Infantry"},
               "BFType" => "CI"
             }).unit_type == "conventional_infantry"
    end

    test "non-infantry types are unaffected by BFType" do
      mech =
        Client.normalize_unit(%{
          "Id" => 39,
          "Name" => "Atlas AS7-D",
          "Type" => %{"Id" => 18, "Name" => "BattleMech"},
          "BFType" => "CI"
        })

      assert mech.unit_type == "battlemech"
      assert mech.bf_type == "CI"

      vehicle =
        Client.normalize_unit(%{
          "Id" => 100,
          "Name" => "Demolisher",
          "Type" => %{"Id" => 19, "Name" => "Combat Vehicle"}
        })

      assert vehicle.unit_type == "combat_vehicle"
      assert vehicle.bf_type == nil

      proto =
        Client.normalize_unit(%{
          "Id" => 200,
          "Name" => "Roc",
          "Type" => %{"Id" => 20, "Name" => "ProtoMech"}
        })

      assert proto.unit_type == "protomech"
    end

    test "unknown type falls back to other" do
      assert Client.normalize_unit(%{
               "Id" => 999,
               "Name" => "Mystery",
               "Type" => %{"Id" => 77, "Name" => "Spaceship"}
             }).unit_type == "other"
    end
  end
end
