defmodule Aces.Units.MasterUnitTest do
  use Aces.DataCase

  alias Aces.Units.MasterUnit

  describe "changeset/2" do
    test "validates required fields" do
      changeset = MasterUnit.changeset(%MasterUnit{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).mul_id
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).unit_type
    end

    test "accepts valid attributes" do
      attrs = %{
        mul_id: 39,
        name: "Atlas",
        variant: "AS7-D",
        unit_type: "battlemech",
        point_value: 48,
        tonnage: 100
      }

      changeset = MasterUnit.changeset(%MasterUnit{}, attrs)
      assert changeset.valid?
    end

    test "validates unit_type inclusion" do
      attrs = %{
        mul_id: 39,
        name: "Atlas", 
        unit_type: "invalid_type"
      }

      changeset = MasterUnit.changeset(%MasterUnit{}, attrs)
      assert "is invalid" in errors_on(changeset).unit_type
    end

    test "validates mul_id uniqueness" do
      # Insert first unit
      units_master_unit_fixture(%{mul_id: 123})

      # Try to insert duplicate
      attrs = %{mul_id: 123, name: "Test", unit_type: "battlemech"}
      changeset = MasterUnit.changeset(%MasterUnit{}, attrs)

      assert {:error, changeset} = Repo.insert(changeset)
      assert "has already been taken" in errors_on(changeset).mul_id
    end
  end

  describe "display_name/1" do
    test "returns name when no variant" do
      unit = %MasterUnit{name: "Atlas", variant: nil}
      assert MasterUnit.display_name(unit) == "Atlas"
    end

    test "returns name with variant when variant exists" do
      unit = %MasterUnit{name: "Atlas", variant: "AS7-D"}
      assert MasterUnit.display_name(unit) == "Atlas AS7-D"
    end
  end

  describe "mul_url/1" do
    test "returns correct MUL URL" do
      unit = %MasterUnit{mul_id: 123}
      assert MasterUnit.mul_url(unit) == "https://www.masterunitlist.info/Unit/Details/123"
    end
  end

  describe "sarna_url/1" do
    test "returns correct Sarna search URL" do
      unit = %MasterUnit{name: "Atlas Assault"}
      expected = "https://www.sarna.net/wiki/Special:Search?search=Atlas%20Assault&go=Go"
      assert MasterUnit.sarna_url(unit) == expected
    end
  end

  describe "sp_per_pv/0" do
    test "returns the standard SP per PV conversion rate" do
      assert MasterUnit.sp_per_pv() == 40
    end
  end

  describe "pv_to_sp/1" do
    test "converts PV to SP at 40:1 ratio" do
      assert MasterUnit.pv_to_sp(25) == 1000
      assert MasterUnit.pv_to_sp(1) == 40
      assert MasterUnit.pv_to_sp(100) == 4000
    end

    test "handles zero PV" do
      assert MasterUnit.pv_to_sp(0) == 0
    end
  end

  describe "sp_cost/1" do
    test "calculates SP cost from unit PV" do
      unit = %MasterUnit{point_value: 25}
      assert MasterUnit.sp_cost(unit) == 1000
    end

    test "returns nil for unit with no point value" do
      unit = %MasterUnit{point_value: nil}
      assert MasterUnit.sp_cost(unit) == nil
    end

    test "handles various PV values" do
      assert MasterUnit.sp_cost(%MasterUnit{point_value: 1}) == 40
      assert MasterUnit.sp_cost(%MasterUnit{point_value: 48}) == 1920
      assert MasterUnit.sp_cost(%MasterUnit{point_value: 100}) == 4000
    end
  end

  describe "sell_price/1" do
    test "calculates sell price as half of SP cost" do
      # 25 PV * 40 = 1000 SP / 2 = 500 SP
      unit = %MasterUnit{point_value: 25}
      assert MasterUnit.sell_price(unit) == 500
    end

    test "returns nil for unit with no point value" do
      unit = %MasterUnit{point_value: nil}
      assert MasterUnit.sell_price(unit) == nil
    end

    test "handles various PV values" do
      assert MasterUnit.sell_price(%MasterUnit{point_value: 1}) == 20
      assert MasterUnit.sell_price(%MasterUnit{point_value: 48}) == 960
      assert MasterUnit.sell_price(%MasterUnit{point_value: 100}) == 2000
    end

    test "handles odd PV values by truncating" do
      # 45 PV * 40 = 1800 SP / 2 = 900 SP
      assert MasterUnit.sell_price(%MasterUnit{point_value: 45}) == 900
      # 1 PV * 40 = 40 SP / 2 = 20 SP
      assert MasterUnit.sell_price(%MasterUnit{point_value: 1}) == 20
    end
  end
end