defmodule Aces.Campaigns.PilotAllocationTest do
  use Aces.DataCase, async: true

  alias Aces.Campaigns.PilotAllocation

  import Aces.CompaniesFixtures

  describe "changeset/2" do
    setup do
      company = company_fixture(status: "active")
      pilot = pilot_fixture(company: company)

      %{company: company, pilot: pilot}
    end

    test "valid initial allocation changeset", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        allocation_type: "initial",
        sp_to_skill: 100,
        sp_to_tokens: 30,
        sp_to_abilities: 20,
        total_sp: 150
      }

      changeset = PilotAllocation.changeset(%PilotAllocation{}, attrs)
      assert changeset.valid?
    end

    test "valid sortie allocation changeset requires sortie_id", %{pilot: pilot, company: company} do
      # First create a campaign and sortie
      campaign = campaign_fixture(company)
      sortie = sortie_fixture(campaign: campaign)

      attrs = %{
        pilot_id: pilot.id,
        sortie_id: sortie.id,
        allocation_type: "sortie",
        sp_to_skill: 50,
        sp_to_tokens: 20,
        sp_to_abilities: 0,
        total_sp: 70
      }

      changeset = PilotAllocation.changeset(%PilotAllocation{}, attrs)
      assert changeset.valid?
    end

    test "requires pilot_id", %{pilot: _pilot} do
      attrs = %{
        allocation_type: "initial",
        sp_to_skill: 100,
        sp_to_tokens: 30,
        sp_to_abilities: 20,
        total_sp: 150
      }

      changeset = PilotAllocation.changeset(%PilotAllocation{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).pilot_id
    end

    test "requires allocation_type", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        sp_to_skill: 100,
        sp_to_tokens: 30,
        sp_to_abilities: 20,
        total_sp: 150
      }

      changeset = PilotAllocation.changeset(%PilotAllocation{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).allocation_type
    end

    test "validates allocation_type is one of 'initial' or 'sortie'", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        allocation_type: "invalid",
        sp_to_skill: 100,
        sp_to_tokens: 30,
        sp_to_abilities: 20,
        total_sp: 150
      }

      changeset = PilotAllocation.changeset(%PilotAllocation{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).allocation_type
    end

    test "validates sp values are non-negative", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        allocation_type: "initial",
        sp_to_skill: -10,
        sp_to_tokens: 30,
        sp_to_abilities: 20,
        total_sp: 40
      }

      changeset = PilotAllocation.changeset(%PilotAllocation{}, attrs)
      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).sp_to_skill
    end

    test "validates total_sp equals sum of allocations", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        allocation_type: "initial",
        sp_to_skill: 100,
        sp_to_tokens: 30,
        sp_to_abilities: 20,
        total_sp: 100  # Should be 150
      }

      changeset = PilotAllocation.changeset(%PilotAllocation{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset).total_sp != []
    end

    test "sortie allocation requires sortie_id", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        allocation_type: "sortie",
        sp_to_skill: 50,
        sp_to_tokens: 20,
        sp_to_abilities: 0,
        total_sp: 70
      }

      changeset = PilotAllocation.changeset(%PilotAllocation{}, attrs)
      refute changeset.valid?
      assert "is required for sortie allocations" in errors_on(changeset).sortie_id
    end

    test "initial allocation must not have sortie_id", %{pilot: pilot, company: company} do
      # Create a campaign and sortie
      campaign = campaign_fixture(company)
      sortie = sortie_fixture(campaign: campaign)

      attrs = %{
        pilot_id: pilot.id,
        sortie_id: sortie.id,  # Should be nil for initial
        allocation_type: "initial",
        sp_to_skill: 100,
        sp_to_tokens: 30,
        sp_to_abilities: 20,
        total_sp: 150
      }

      changeset = PilotAllocation.changeset(%PilotAllocation{}, attrs)
      refute changeset.valid?
      assert "must be nil for initial allocations" in errors_on(changeset).sortie_id
    end

    test "validates edge abilities are valid", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        allocation_type: "initial",
        sp_to_skill: 0,
        sp_to_tokens: 0,
        sp_to_abilities: 60,
        edge_abilities_gained: ["InvalidAbility"],
        total_sp: 60
      }

      changeset = PilotAllocation.changeset(%PilotAllocation{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset).edge_abilities_gained != []
    end

    test "accepts valid edge abilities", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        allocation_type: "initial",
        sp_to_skill: 0,
        sp_to_tokens: 0,
        sp_to_abilities: 60,
        edge_abilities_gained: ["Gunnery"],
        total_sp: 60
      }

      changeset = PilotAllocation.changeset(%PilotAllocation{}, attrs)
      assert changeset.valid?
    end
  end

  describe "initial_changeset/2" do
    setup do
      company = company_fixture(status: "active")
      pilot = pilot_fixture(company: company)

      %{pilot: pilot}
    end

    test "sets allocation_type to 'initial' and sortie_id to nil", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        sp_to_skill: 100,
        sp_to_tokens: 30,
        sp_to_abilities: 20,
        total_sp: 150
      }

      changeset = PilotAllocation.initial_changeset(%PilotAllocation{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :allocation_type) == "initial"
      assert Ecto.Changeset.get_change(changeset, :sortie_id) == nil
    end
  end

  describe "sortie_changeset/2" do
    setup do
      company = company_fixture(status: "active")
      pilot = pilot_fixture(company: company)
      campaign = campaign_fixture(company)
      sortie = sortie_fixture(campaign: campaign)

      %{pilot: pilot, sortie: sortie}
    end

    test "sets allocation_type to 'sortie' and requires sortie_id", %{pilot: pilot, sortie: sortie} do
      attrs = %{
        pilot_id: pilot.id,
        sortie_id: sortie.id,
        sp_to_skill: 50,
        sp_to_tokens: 20,
        sp_to_abilities: 0,
        total_sp: 70
      }

      changeset = PilotAllocation.sortie_changeset(%PilotAllocation{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :allocation_type) == "sortie"
    end

    test "fails without sortie_id", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        sp_to_skill: 50,
        sp_to_tokens: 20,
        sp_to_abilities: 0,
        total_sp: 70
      }

      changeset = PilotAllocation.sortie_changeset(%PilotAllocation{}, attrs)
      refute changeset.valid?
      assert "is required for sortie allocations" in errors_on(changeset).sortie_id
    end
  end

  describe "database constraints" do
    setup do
      company = company_fixture(status: "active")
      pilot = pilot_fixture(company: company)
      campaign = campaign_fixture(company)
      sortie = sortie_fixture(campaign: campaign)

      %{pilot: pilot, sortie: sortie, campaign: campaign}
    end

    test "pilot can only have one initial allocation", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        allocation_type: "initial",
        sp_to_skill: 100,
        sp_to_tokens: 30,
        sp_to_abilities: 20,
        total_sp: 150
      }

      # First insert should succeed
      {:ok, _allocation} =
        %PilotAllocation{}
        |> PilotAllocation.changeset(attrs)
        |> Aces.Repo.insert()

      # Second insert should fail due to unique constraint
      {:error, changeset} =
        %PilotAllocation{}
        |> PilotAllocation.changeset(attrs)
        |> Aces.Repo.insert()

      assert "pilot already has an initial allocation" in errors_on(changeset).pilot_id
    end

    test "pilot can only have one allocation per sortie", %{pilot: pilot, sortie: sortie} do
      attrs = %{
        pilot_id: pilot.id,
        sortie_id: sortie.id,
        allocation_type: "sortie",
        sp_to_skill: 50,
        sp_to_tokens: 20,
        sp_to_abilities: 0,
        total_sp: 70
      }

      # First insert should succeed
      {:ok, _allocation} =
        %PilotAllocation{}
        |> PilotAllocation.changeset(attrs)
        |> Aces.Repo.insert()

      # Second insert should fail due to unique constraint
      {:error, changeset} =
        %PilotAllocation{}
        |> PilotAllocation.changeset(attrs)
        |> Aces.Repo.insert()

      assert "pilot already has an allocation for this sortie" in errors_on(changeset).sortie_id
    end

    test "pilot can have allocations for multiple sorties", %{pilot: pilot, sortie: sortie, campaign: campaign} do
      # Create another sortie
      sortie2 = sortie_fixture(campaign: campaign)

      attrs1 = %{
        pilot_id: pilot.id,
        sortie_id: sortie.id,
        allocation_type: "sortie",
        sp_to_skill: 50,
        sp_to_tokens: 20,
        sp_to_abilities: 0,
        total_sp: 70
      }

      attrs2 = %{
        pilot_id: pilot.id,
        sortie_id: sortie2.id,
        allocation_type: "sortie",
        sp_to_skill: 30,
        sp_to_tokens: 0,
        sp_to_abilities: 40,
        total_sp: 70
      }

      # Both inserts should succeed
      {:ok, _allocation1} =
        %PilotAllocation{}
        |> PilotAllocation.changeset(attrs1)
        |> Aces.Repo.insert()

      {:ok, _allocation2} =
        %PilotAllocation{}
        |> PilotAllocation.changeset(attrs2)
        |> Aces.Repo.insert()
    end

    test "deleting a pilot cascades to their allocations", %{pilot: pilot} do
      attrs = %{
        pilot_id: pilot.id,
        allocation_type: "initial",
        sp_to_skill: 100,
        sp_to_tokens: 30,
        sp_to_abilities: 20,
        total_sp: 150
      }

      {:ok, allocation} =
        %PilotAllocation{}
        |> PilotAllocation.changeset(attrs)
        |> Aces.Repo.insert()

      # Delete the pilot
      Aces.Repo.delete!(pilot)

      # Allocation should be gone
      assert is_nil(Aces.Repo.get(PilotAllocation, allocation.id))
    end

    test "deleting a sortie cascades to associated allocations", %{pilot: pilot, sortie: sortie} do
      attrs = %{
        pilot_id: pilot.id,
        sortie_id: sortie.id,
        allocation_type: "sortie",
        sp_to_skill: 50,
        sp_to_tokens: 20,
        sp_to_abilities: 0,
        total_sp: 70
      }

      {:ok, allocation} =
        %PilotAllocation{}
        |> PilotAllocation.changeset(attrs)
        |> Aces.Repo.insert()

      # Delete the sortie
      Aces.Repo.delete!(sortie)

      # Allocation should be gone
      assert is_nil(Aces.Repo.get(PilotAllocation, allocation.id))
    end
  end

  describe "allocation_types/0" do
    test "returns valid allocation types" do
      assert PilotAllocation.allocation_types() == ~w(initial sortie)
    end
  end
end
