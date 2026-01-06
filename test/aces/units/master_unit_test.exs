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
end