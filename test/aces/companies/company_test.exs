defmodule Aces.Companies.CompanyTest do
  use Aces.DataCase

  alias Aces.Companies.Company

  describe "changeset/2" do
    test "validates required fields" do
      changeset = Company.changeset(%Company{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "accepts valid attributes" do
      attrs = %{
        name: "Test Company",
        description: "A great company",
        warchest_balance: 5000,
        pv_budget: 600
      }

      changeset = Company.changeset(%Company{}, attrs)
      assert changeset.valid?
    end

    test "validates name length" do
      long_name = String.duplicate("a", 256)
      changeset = Company.changeset(%Company{}, %{name: long_name})

      assert "should be at most 255 character(s)" in errors_on(changeset).name
    end

    test "validates description length" do
      long_description = String.duplicate("a", 2001)
      changeset = Company.changeset(%Company{}, %{name: "Test", description: long_description})

      assert "should be at most 2000 character(s)" in errors_on(changeset).description
    end

    test "validates warchest_balance is non-negative" do
      changeset = Company.changeset(%Company{}, %{name: "Test", warchest_balance: -100})

      assert "must be greater than or equal to 0" in errors_on(changeset).warchest_balance
    end

    test "allows zero warchest_balance" do
      changeset = Company.changeset(%Company{}, %{name: "Test", warchest_balance: 0})

      assert changeset.valid?
    end

    test "validates pv_budget is non-negative" do
      changeset = Company.changeset(%Company{}, %{name: "Test", pv_budget: -50})

      assert "must be greater than or equal to 0" in errors_on(changeset).pv_budget
    end

    test "allows zero pv_budget" do
      changeset = Company.changeset(%Company{}, %{name: "Test", pv_budget: 0})

      assert changeset.valid?
    end
  end

  describe "creation_changeset/2" do
    test "sets default warchest_balance to 0 when not provided" do
      changeset = Company.creation_changeset(%Company{}, %{name: "Test"})

      assert changeset.valid?
      # When warchest_balance is 0, it's set via put_change
      assert Ecto.Changeset.get_field(changeset, :warchest_balance) == 0
    end

    test "uses provided warchest_balance" do
      changeset = Company.creation_changeset(%Company{}, %{name: "Test", warchest_balance: 5000})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :warchest_balance) == 5000
    end

    test "sets default pv_budget to 400 when not provided" do
      changeset = Company.creation_changeset(%Company{}, %{name: "Test"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :pv_budget) == 400
    end

    test "uses provided pv_budget" do
      changeset = Company.creation_changeset(%Company{}, %{name: "Test", pv_budget: 600})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :pv_budget) == 600
    end
  end
end
