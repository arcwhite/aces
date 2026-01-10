defmodule Aces.Companies.PilotTest do
  use Aces.DataCase

  alias Aces.Companies.Pilot

  import Aces.CompaniesFixtures

  @valid_attrs %{
    name: "Test Pilot",
    callsign: "Maverick", 
    description: "A skilled pilot",
    sp_allocated_to_skill: 0,
    sp_allocated_to_edge_tokens: 0,
    sp_allocated_to_edge_abilities: 60,
    sp_available: 90,  # 150 - 0 - 0 - 60 = 90
    skill_level: 4,   # Starting skill level
    edge_tokens: 1,   # Starting edge tokens
    edge_abilities: ["Accurate"],
    sp_earned: 0
  }

  @invalid_attrs %{
    name: nil,
    sp_allocated_to_skill: -10,
    sp_allocated_to_edge_tokens: -5,
    sp_allocated_to_edge_abilities: -3
  }

  def pilot_fixture(attrs \\ %{}) do
    company = company_fixture()

    attrs =
      attrs
      |> Enum.into(@valid_attrs)
      |> Map.put(:company_id, company.id)

    {:ok, pilot} = Aces.Companies.create_pilot(company, attrs)
    pilot
  end

  describe "changeset/2" do
    test "changeset with valid data is valid" do
      company = company_fixture()
      attrs = Map.put(@valid_attrs, :company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      assert changeset.valid?
    end

    test "changeset with invalid data is invalid" do
      changeset = Pilot.changeset(%Pilot{}, @invalid_attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "name is required" do
      attrs = Map.delete(@valid_attrs, :name)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "name must not be empty after trimming" do
      attrs = Map.put(@valid_attrs, :name, "   ")
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "callsign is optional" do
      company = company_fixture()
      attrs = @valid_attrs 
      |> Map.delete(:callsign)
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      assert changeset.valid?
    end

    test "skill level must be between 0 and 4" do
      company = company_fixture()
      
      # Test that skill level 4 with 0 SP is valid (starting case)
      attrs = @valid_attrs
      |> Map.put(:skill_level, 4)
      |> Map.put(:sp_allocated_to_skill, 0)
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      assert changeset.valid?

      # Test invalid values
      for skill_level <- [-1, 5, 10] do
        attrs = @valid_attrs
        |> Map.put(:skill_level, skill_level)
        |> Map.put(:company_id, company.id)
        changeset = Pilot.changeset(%Pilot{}, attrs)
        refute changeset.valid?, "Skill level #{skill_level} should be invalid"
      end
    end
  end

  describe "SP allocation validations" do
    test "individual SP allocations cannot exceed total available SP" do
      company = company_fixture()
      
      # Test skill SP exceeding limit
      attrs = @valid_attrs
      |> Map.put(:sp_allocated_to_skill, 200)  # 200 > 150 starting SP
      |> Map.put(:sp_allocated_to_edge_tokens, 0)
      |> Map.put(:sp_allocated_to_edge_abilities, 0)
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "cannot exceed total available SP (150)" in errors_on(changeset).sp_allocated_to_skill

      # Test edge tokens SP exceeding limit
      attrs = @valid_attrs
      |> Map.put(:sp_allocated_to_skill, 0)
      |> Map.put(:sp_allocated_to_edge_tokens, 200)  # 200 > 150 starting SP
      |> Map.put(:sp_allocated_to_edge_abilities, 0)
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "cannot exceed total available SP (150)" in errors_on(changeset).sp_allocated_to_edge_tokens

      # Test edge abilities SP exceeding limit
      attrs = @valid_attrs
      |> Map.put(:sp_allocated_to_skill, 0)
      |> Map.put(:sp_allocated_to_edge_tokens, 0)
      |> Map.put(:sp_allocated_to_edge_abilities, 200)  # 200 > 150 starting SP
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "cannot exceed total available SP (150)" in errors_on(changeset).sp_allocated_to_edge_abilities
    end

    test "total SP allocation cannot exceed available SP" do
      company = company_fixture()
      
      attrs = @valid_attrs
      |> Map.put(:sp_allocated_to_skill, 60)
      |> Map.put(:sp_allocated_to_edge_tokens, 60)
      |> Map.put(:sp_allocated_to_edge_abilities, 60)  # Total: 180 > 150 starting SP
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "Total SP allocation (180) exceeds available SP (150)" in errors_on(changeset).base
    end

    test "SP allocations must be non-negative" do
      company = company_fixture()
      
      attrs = @valid_attrs
      |> Map.put(:sp_allocated_to_skill, -10)
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).sp_allocated_to_skill
    end

    test "earned SP increases available SP for allocation" do
      company = company_fixture()
      
      # With 100 earned SP, total available is 250
      attrs = @valid_attrs
      |> Map.put(:sp_earned, 100)
      |> Map.put(:sp_allocated_to_skill, 200)  # Would be invalid with only 150 SP
      |> Map.put(:sp_allocated_to_edge_tokens, 30)
      |> Map.put(:sp_allocated_to_edge_abilities, 20)  # Total: 250, should be valid
      |> Map.put(:sp_available, 0)  # 250 - 250 = 0
      |> Map.put(:skill_level, 4)  # 200 SP not enough for skill improvement
      |> Map.put(:edge_tokens, 1)   # 30 SP gives only 1 token (need 60 for 2nd)
      |> Map.put(:edge_abilities, [])  # 20 SP gives 0 abilities (need 60 for 1st)
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      assert changeset.valid?
    end

    test "SP allocation consistency validation" do
      company = company_fixture()
      
      attrs = @valid_attrs
      |> Map.put(:sp_allocated_to_skill, 60)
      |> Map.put(:sp_allocated_to_edge_tokens, 60)
      |> Map.put(:sp_allocated_to_edge_abilities, 30)
      |> Map.put(:sp_available, 0)  # Should be 150 - 60 - 60 - 30 = 0
      |> Map.put(:edge_abilities, [])  # 30 SP = 0 abilities (need 60 for first)
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      assert changeset.valid?

      # Test inconsistent SP calculation
      attrs = attrs |> Map.put(:sp_available, 50)  # Wrong value
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "SP allocation doesn't add up correctly" in errors_on(changeset).sp_available
    end
  end

  describe "derived field validations" do
    test "skill level must match allocated SP" do
      company = company_fixture()
      
      # 0 SP should give skill level 4 (starting level)
      attrs = @valid_attrs
      |> Map.put(:sp_allocated_to_skill, 0)
      |> Map.put(:skill_level, 2)  # Wrong skill level
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "Skill level doesn't match allocated SP" in errors_on(changeset).skill_level
    end

    test "edge tokens must match allocated SP" do
      company = company_fixture()
      
      # 0 SP should give 1 edge token (starting amount)
      attrs = @valid_attrs
      |> Map.put(:sp_allocated_to_edge_tokens, 0)
      |> Map.put(:edge_tokens, 3)  # Wrong token count
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "Edge tokens don't match allocated SP" in errors_on(changeset).edge_tokens
    end
  end

  describe "edge abilities validations" do
    test "edge abilities must be from valid list" do
      company = company_fixture()
      
      attrs = @valid_attrs
      |> Map.put(:edge_abilities, ["Accurate", "InvalidAbility"])
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "contains invalid abilities: InvalidAbility" in errors_on(changeset).edge_abilities
    end

    test "edge abilities count must not exceed SP allocation" do
      company = company_fixture()
      
      # 60 SP only allows 1 edge ability
      attrs = @valid_attrs
      |> Map.put(:sp_allocated_to_edge_abilities, 60)
      |> Map.put(:edge_abilities, ["Accurate", "Dodge"])  # 2 abilities, but only 1 allowed
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      assert "too many abilities selected for allocated SP" in errors_on(changeset).edge_abilities
    end

    test "edge abilities can be provided as JSON string" do
      company = company_fixture()
      
      attrs = @valid_attrs
      |> Map.put(:edge_abilities, Jason.encode!(["Accurate"]))
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      assert changeset.valid?
      assert get_field(changeset, :edge_abilities) == ["Accurate"]
    end
  end

  describe "SP calculation functions" do
    test "calculate_skill_from_sp/1" do
      assert Pilot.calculate_skill_from_sp(0) == 4    # Starting skill
      assert Pilot.calculate_skill_from_sp(300) == 4  # Not enough for skill 3
      assert Pilot.calculate_skill_from_sp(400) == 3  # Exactly skill 3
      assert Pilot.calculate_skill_from_sp(800) == 3  # Still skill 3
      assert Pilot.calculate_skill_from_sp(900) == 2  # Skill 2
      assert Pilot.calculate_skill_from_sp(1900) == 1 # Skill 1
      assert Pilot.calculate_skill_from_sp(3400) == 0 # Skill 0
      assert Pilot.calculate_skill_from_sp(5000) == 0 # Still skill 0
    end

    test "calculate_edge_tokens_from_sp/1" do
      assert Pilot.calculate_edge_tokens_from_sp(0) == 1   # Free token
      assert Pilot.calculate_edge_tokens_from_sp(50) == 1  # Not enough for 2nd
      assert Pilot.calculate_edge_tokens_from_sp(60) == 2  # 2nd token
      assert Pilot.calculate_edge_tokens_from_sp(120) == 3 # 3rd token
      assert Pilot.calculate_edge_tokens_from_sp(200) == 4 # 4th token
      assert Pilot.calculate_edge_tokens_from_sp(300) == 5 # 5th token
    end

    test "calculate_edge_abilities_from_sp/1" do
      assert Pilot.calculate_edge_abilities_from_sp(0) == 0   # No abilities
      assert Pilot.calculate_edge_abilities_from_sp(50) == 0  # Not enough for 1st
      assert Pilot.calculate_edge_abilities_from_sp(60) == 1  # 1st ability
      assert Pilot.calculate_edge_abilities_from_sp(180) == 2 # 2nd ability
      assert Pilot.calculate_edge_abilities_from_sp(360) == 3 # 3rd ability
      assert Pilot.calculate_edge_abilities_from_sp(600) == 4 # 4th ability
      assert Pilot.calculate_edge_abilities_from_sp(900) == 5 # 5th ability
    end

    test "available_edge_abilities/0 returns valid list" do
      abilities = Pilot.available_edge_abilities()
      assert is_list(abilities)
      assert length(abilities) > 0
      assert "Accurate" in abilities
      assert "Dodge" in abilities
    end
  end

  describe "security edge cases" do
    test "extremely large SP values are rejected" do
      company = company_fixture()
      
      attrs = @valid_attrs
      |> Map.put(:sp_allocated_to_skill, 999_999_999)
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
    end

    test "negative SP values are rejected" do
      company = company_fixture()
      
      for field <- [:sp_allocated_to_skill, :sp_allocated_to_edge_tokens, :sp_allocated_to_edge_abilities] do
        attrs = @valid_attrs
        |> Map.put(field, -100)
        |> Map.put(:company_id, company.id)
        changeset = Pilot.changeset(%Pilot{}, attrs)
        refute changeset.valid?, "Negative #{field} should be invalid"
      end
    end

    test "malicious edge abilities injection is prevented" do
      company = company_fixture()
      
      # Try script injection
      attrs = @valid_attrs
      |> Map.put(:edge_abilities, ["<script>alert('xss')</script>"])
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
      
      # Try SQL injection-like strings
      attrs = @valid_attrs
      |> Map.put(:edge_abilities, ["'; DROP TABLE pilots; --"])
      |> Map.put(:company_id, company.id)
      changeset = Pilot.changeset(%Pilot{}, attrs)
      refute changeset.valid?
    end
  end
end