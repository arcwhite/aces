defmodule Aces.MUL.TypeMappingTest do
  use ExUnit.Case, async: true

  alias Aces.MUL.TypeMapping

  describe "to_mul_ids/1" do
    test "canonical internal types map to their MUL id" do
      assert TypeMapping.to_mul_ids("battlemech") == [18]
      assert TypeMapping.to_mul_ids("combat_vehicle") == [19]
      assert TypeMapping.to_mul_ids("protomech") == [20]
      assert TypeMapping.to_mul_ids("infantry") == [21]
    end

    test "battle_armor and conventional_infantry both hit MUL Type-21" do
      assert TypeMapping.to_mul_ids("battle_armor") == [21]
      assert TypeMapping.to_mul_ids("conventional_infantry") == [21]
    end

    test "shorthand aliases resolve to the canonical id" do
      assert TypeMapping.to_mul_ids("mech") == [18]
      assert TypeMapping.to_mul_ids("vehicle") == [19]
    end

    test "lookup is case-insensitive" do
      assert TypeMapping.to_mul_ids("BattleMech") == [18]
      assert TypeMapping.to_mul_ids("INFANTRY") == [21]
    end

    test "unknown or nil returns empty list" do
      assert TypeMapping.to_mul_ids(nil) == []
      assert TypeMapping.to_mul_ids("dropship") == []
      assert TypeMapping.to_mul_ids("") == []
    end
  end

  describe "supported_mul_type_ids/0" do
    test "matches the modal's supported set (BM/CV/PM/Infantry)" do
      assert TypeMapping.supported_mul_type_ids() == [18, 19, 20, 21]
    end
  end

  describe "resolve/2 — BFType-first" do
    test "BM/PM/CV/BA/CI resolve directly from BFType" do
      assert TypeMapping.resolve(%{"Id" => 18}, "BM") == "battlemech"
      assert TypeMapping.resolve(%{"Id" => 20}, "PM") == "protomech"
      assert TypeMapping.resolve(%{"Id" => 19}, "CV") == "combat_vehicle"
      assert TypeMapping.resolve(%{"Id" => 21}, "BA") == "battle_armor"
      assert TypeMapping.resolve(%{"Id" => 21}, "CI") == "conventional_infantry"
    end

    test "collapsed types (IM → battlemech, SV → combat_vehicle)" do
      assert TypeMapping.resolve(%{"Id" => 18}, "IM") == "battlemech"
      assert TypeMapping.resolve(%{"Id" => 19}, "SV") == "combat_vehicle"
    end

    test "aerospace / large-craft BFTypes resolve to \"other\"" do
      for bf <- ~w(AF CF SC DS DA JS WS SS MS) do
        assert TypeMapping.resolve(%{"Id" => 77}, bf) == "other",
               "expected BFType #{bf} to resolve to \"other\""
      end
    end

    test "BFType comparison is case-insensitive" do
      assert TypeMapping.resolve(%{"Id" => 21}, "ba") == "battle_armor"
      assert TypeMapping.resolve(%{"Id" => 21}, "ci") == "conventional_infantry"
    end

    test "BFType wins over Type.Id when both are known" do
      # A payload with BFType CI but Type.Id 18 (BattleMech) — the plan
      # inverts precedence, so BFType decides. Real data shouldn't do this
      # but the rule needs to be pinned.
      assert TypeMapping.resolve(%{"Id" => 18}, "CI") == "conventional_infantry"
    end
  end

  describe "resolve/2 — Type.Id / Type.Name fallback" do
    test "no BFType → Type.Id table for 18/19/20" do
      assert TypeMapping.resolve(%{"Id" => 18}, nil) == "battlemech"
      assert TypeMapping.resolve(%{"Id" => 19}, nil) == "combat_vehicle"
      assert TypeMapping.resolve(%{"Id" => 20}, nil) == "protomech"
    end

    test "Type.Id 21 with no BFType is unclassifiable → \"other\"" do
      assert TypeMapping.resolve(%{"Id" => 21}, nil) == "other"
    end

    test "Type.Name is used when Type.Id is absent" do
      assert TypeMapping.resolve(%{"Name" => "BattleMech"}, nil) == "battlemech"
      assert TypeMapping.resolve(%{"Name" => "Combat Vehicle"}, nil) == "combat_vehicle"
      assert TypeMapping.resolve(%{"Name" => "ProtoMech"}, nil) == "protomech"
    end

    test "bare Type.Name string works too" do
      assert TypeMapping.resolve("BattleMech", nil) == "battlemech"
      assert TypeMapping.resolve("mech", nil) == "battlemech"
    end

    test "unknown Type.Name / Type.Id / BFType all resolve to \"other\"" do
      assert TypeMapping.resolve(%{"Id" => 999}, nil) == "other"
      assert TypeMapping.resolve(%{"Name" => "Spaceship"}, nil) == "other"
      assert TypeMapping.resolve(nil, nil) == "other"
    end
  end
end
