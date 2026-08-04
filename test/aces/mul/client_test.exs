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

    test "infantry payload with missing/unknown BFType falls through to \"other\"" do
      # Under BFType-first resolution a bare Type.Id-21 payload is
      # unclassifiable — 21 covers both BA and CI, and only BFType can tell
      # them apart. The fallback table deliberately omits 21 so these rows
      # surface as "other" (and are logged) instead of silently bucketing
      # into battle_armor.
      assert Client.normalize_unit(%{
               "Id" => 3,
               "Name" => "No BFType",
               "Type" => %{"Id" => 21}
             }).unit_type == "other"

      assert Client.normalize_unit(%{
               "Id" => 4,
               "Name" => "Odd BFType",
               "Type" => %{"Id" => 21},
               "BFType" => "???"
             }).unit_type == "other"
    end

    test "infantry resolved by type Name when no Id is present" do
      assert Client.normalize_unit(%{
               "Id" => 5,
               "Name" => "Name-only Infantry",
               "Type" => %{"Name" => "Infantry"},
               "BFType" => "CI"
             }).unit_type == "conventional_infantry"
    end

    test "known BFType wins over Type.Id (BFType-first precedence)" do
      # If BFType is present and known, it decides — even for non-infantry
      # rows. This case shouldn't occur in real MUL data (Type.Id 18 with
      # BFType CI would be a data glitch), but the precedence rule is the
      # whole point of the new resolver, so we pin the behaviour here.
      mech_with_bogus_ci =
        Client.normalize_unit(%{
          "Id" => 39,
          "Name" => "Atlas AS7-D",
          "Type" => %{"Id" => 18, "Name" => "BattleMech"},
          "BFType" => "CI"
        })

      assert mech_with_bogus_ci.unit_type == "conventional_infantry"
      assert mech_with_bogus_ci.bf_type == "CI"
    end

    test "IndustrialMech (BFType \"IM\") collapses to battlemech" do
      assert Client.normalize_unit(%{
               "Id" => 500,
               "Name" => "Carbine IndustrialMech",
               "Type" => %{"Id" => 18, "Name" => "BattleMech"},
               "BFType" => "IM"
             }).unit_type == "battlemech"
    end

    test "Support Vehicle (BFType \"SV\") collapses to combat_vehicle" do
      assert Client.normalize_unit(%{
               "Id" => 501,
               "Name" => "Ferret Support VTOL",
               "Type" => %{"Id" => 19, "Name" => "Combat Vehicle"},
               "BFType" => "SV"
             }).unit_type == "combat_vehicle"
    end

    test "aerospace / large craft BFType values resolve to other" do
      for bf <- ~w(AF CF SC DS DA JS WS SS MS) do
        unit =
          Client.normalize_unit(%{
            "Id" => 600,
            "Name" => "Aero example",
            "Type" => %{"Id" => 77, "Name" => "AerospaceFighter"},
            "BFType" => bf
          })

        assert unit.unit_type == "other", "expected BFType #{bf} to resolve to other"
      end
    end

    test "non-infantry types with no BFType still use Type.Id fallback" do
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

  describe "fetch_units/1 dispatch" do
    test "test env is wired to the fixture source" do
      assert Application.get_env(:aces, :mul_client_source) == :fixture
    end

    test "returns the typed {:ok, {units, :fixture}} contract" do
      assert {:ok, {units, :fixture}} = Client.fetch_units(%{name: "Atlas"})
      assert Enum.any?(units, &(&1.name == "Atlas"))
    end
  end
end
