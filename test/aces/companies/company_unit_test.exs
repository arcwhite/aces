defmodule Aces.Companies.CompanyUnitTest do
  use Aces.DataCase

  alias Aces.Companies.CompanyUnit
  alias Aces.CompaniesFixtures

  describe "changeset/2" do
    test "validates required fields" do
      changeset = CompanyUnit.changeset(%CompanyUnit{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).company_id
      assert "can't be blank" in errors_on(changeset).master_unit_id
    end

    test "accepts valid attributes" do
      company = CompaniesFixtures.company_fixture()
      master_unit = CompaniesFixtures.master_unit_fixture()

      attrs = %{
        company_id: company.id,
        master_unit_id: master_unit.id,
        custom_name: "Custom Name",
        status: "operational",
        purchase_cost_sp: 1000
      }

      changeset = CompanyUnit.changeset(%CompanyUnit{}, attrs)
      assert changeset.valid?
    end

    test "validates status inclusion" do
      company = CompaniesFixtures.company_fixture()
      master_unit = CompaniesFixtures.master_unit_fixture()

      attrs = %{
        company_id: company.id,
        master_unit_id: master_unit.id,
        status: "invalid_status"
      }

      changeset = CompanyUnit.changeset(%CompanyUnit{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "validates purchase_cost_sp is non-negative" do
      company = CompaniesFixtures.company_fixture()
      master_unit = CompaniesFixtures.master_unit_fixture()

      attrs = %{
        company_id: company.id,
        master_unit_id: master_unit.id,
        purchase_cost_sp: -100
      }

      changeset = CompanyUnit.changeset(%CompanyUnit{}, attrs)
      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).purchase_cost_sp
    end
  end

  describe "draft_company_changeset/2" do
    setup do
      company = CompaniesFixtures.company_fixture(%{status: "draft"})
      # Preload company_units to avoid database query issues in validations
      company = Aces.Repo.preload(company, company_units: [:master_unit])

      battlemech1 = CompaniesFixtures.master_unit_fixture(%{
        name: "BattleMaster BLR-4S",
        variant: "BLR-4S",
        unit_type: "battlemech",
        point_value: 85
      })

      battlemech2 = CompaniesFixtures.master_unit_fixture(%{
        name: "BattleMaster BLR-M3",
        variant: "BLR-M3",
        unit_type: "battlemech",
        point_value: 90
      })

      different_chassis = CompaniesFixtures.master_unit_fixture(%{
        name: "Marauder MAD-4R",
        variant: "MAD-4R",
        unit_type: "battlemech",
        point_value: 67
      })

      %{
        company: company,
        battlemech1: battlemech1,
        battlemech2: battlemech2,
        different_chassis: different_chassis
      }
    end

    test "validates company is in draft status", %{battlemech1: battlemech1} do
      company = CompaniesFixtures.company_fixture(%{status: "active"})

      attrs = %{
        company_id: company.id,
        master_unit_id: battlemech1.id
      }

      changeset = CompanyUnit.draft_company_changeset(%CompanyUnit{}, attrs)
      refute changeset.valid?
      assert "Cannot add units to active companies" in errors_on(changeset).company_id
    end

    test "validates unit type is allowed", %{company: company} do
      invalid_unit = CompaniesFixtures.master_unit_fixture(%{
        unit_type: "aerospace_fighter"
      })

      attrs = %{
        company_id: company.id,
        master_unit_id: invalid_unit.id
      }

      changeset = CompanyUnit.draft_company_changeset(%CompanyUnit{}, attrs)
      refute changeset.valid?
      assert "Only types Battlemech, Battle Armor, Combat Vehicle, Conventional Infantry are allowed" in errors_on(changeset).master_unit_id
    end

    test "validates PV budget", %{company: company} do
      expensive_unit = CompaniesFixtures.master_unit_fixture(%{
        point_value: 999,  # More than default PV budget of 400
        unit_type: "battlemech"
      })

      attrs = %{
        company_id: company.id,
        master_unit_id: expensive_unit.id
      }

      changeset = CompanyUnit.draft_company_changeset(%CompanyUnit{}, attrs)
      refute changeset.valid?
      assert String.contains?(List.first(errors_on(changeset).master_unit_id), "Insufficient PV budget")
    end
  end

  describe "chassis extraction and validation" do
    setup do
      company = CompaniesFixtures.company_fixture(%{status: "draft", pv_budget: 1000})
      company = Aces.Repo.preload(company, company_units: [:master_unit])

      blr_4s = CompaniesFixtures.master_unit_fixture(%{
        name: "BattleMaster BLR-4S",
        variant: "BLR-4S",
        unit_type: "battlemech",
        point_value: 85
      })

      blr_m3 = CompaniesFixtures.master_unit_fixture(%{
        name: "BattleMaster BLR-M3",
        variant: "BLR-M3",
        unit_type: "battlemech",
        point_value: 90
      })

      blr_3m = CompaniesFixtures.master_unit_fixture(%{
        name: "BattleMaster BLR-3M",
        variant: "BLR-3M",
        unit_type: "battlemech",
        point_value: 88
      })

      mad_4r = CompaniesFixtures.master_unit_fixture(%{
        name: "Marauder MAD-4R",
        variant: "MAD-4R",
        unit_type: "battlemech",
        point_value: 67
      })

      %{
        company: company,
        blr_4s: blr_4s,
        blr_m3: blr_m3,
        blr_3m: blr_3m,
        mad_4r: mad_4r
      }
    end

    test "allows first battlemech of a chassis", %{company: company, blr_4s: blr_4s} do
      attrs = %{
        company_id: company.id,
        master_unit_id: blr_4s.id
      }

      changeset = CompanyUnit.draft_company_changeset(%CompanyUnit{}, attrs)
      assert changeset.valid?
    end

    test "allows second battlemech of same chassis with different variant", %{company: company, blr_4s: blr_4s, blr_m3: blr_m3} do
      # Add first BLR unit
      CompaniesFixtures.company_unit_fixture(%{
        company: company,
        master_unit: blr_4s
      })

      # Reload company to get updated associations
      company = Aces.Companies.get_company!(company.id)

      attrs = %{
        company_id: company.id,
        master_unit_id: blr_m3.id
      }

      changeset = CompanyUnit.draft_company_changeset(%CompanyUnit{}, attrs)
      assert changeset.valid?
    end

    test "prevents third battlemech of same chassis", %{company: company, blr_4s: blr_4s, blr_m3: blr_m3, blr_3m: blr_3m} do
      # Add first two BLR units
      CompaniesFixtures.company_unit_fixture(%{
        company: company,
        master_unit: blr_4s
      })

      CompaniesFixtures.company_unit_fixture(%{
        company: company,
        master_unit: blr_m3
      })

      # Reload company to get updated associations
      company = Aces.Companies.get_company!(company.id)

      attrs = %{
        company_id: company.id,
        master_unit_id: blr_3m.id
      }

      changeset = CompanyUnit.draft_company_changeset(%CompanyUnit{}, attrs)
      refute changeset.valid?
      assert "Cannot add more than 2 Battlemechs of the same chassis" in errors_on(changeset).master_unit_id
    end

    test "prevents duplicate variants of same chassis", %{company: company, blr_4s: blr_4s} do
      # Add first BLR-4S
      CompaniesFixtures.company_unit_fixture(%{
        company: company,
        master_unit: blr_4s
      })

      # Reload company to get updated associations
      company = Aces.Companies.get_company!(company.id)

      attrs = %{
        company_id: company.id,
        master_unit_id: blr_4s.id
      }

      changeset = CompanyUnit.draft_company_changeset(%CompanyUnit{}, attrs)
      refute changeset.valid?
      assert "Cannot add duplicate Battlemech variants of the same chassis" in errors_on(changeset).master_unit_id
    end

    test "allows different chassis after reaching limit on one chassis", %{company: company, blr_4s: blr_4s, blr_m3: blr_m3, mad_4r: mad_4r} do
      # Add two BLR units (max for BLR chassis)
      CompaniesFixtures.company_unit_fixture(%{
        company: company,
        master_unit: blr_4s
      })

      CompaniesFixtures.company_unit_fixture(%{
        company: company,
        master_unit: blr_m3
      })

      # Reload company to get updated associations
      company = Aces.Companies.get_company!(company.id)

      # Should still be able to add MAD-4R (different chassis)
      attrs = %{
        company_id: company.id,
        master_unit_id: mad_4r.id
      }

      changeset = CompanyUnit.draft_company_changeset(%CompanyUnit{}, attrs)
      assert changeset.valid?
    end
  end

  describe "non-battlemech validation" do
    setup do
      company = CompaniesFixtures.company_fixture(%{status: "draft", pv_budget: 1000})
      company = Aces.Repo.preload(company, company_units: [:master_unit])

      battle_armor = CompaniesFixtures.master_unit_fixture(%{
        name: "Elemental Battle Armor",
        variant: "Standard",
        unit_type: "battle_armor",
        point_value: 10
      })

      %{company: company, battle_armor: battle_armor}
    end

    test "allows first unit of a type", %{company: company, battle_armor: battle_armor} do
      attrs = %{
        company_id: company.id,
        master_unit_id: battle_armor.id
      }

      changeset = CompanyUnit.draft_company_changeset(%CompanyUnit{}, attrs)
      assert changeset.valid?
    end

    test "allows second identical unit", %{company: company, battle_armor: battle_armor} do
      # Add first unit
      CompaniesFixtures.company_unit_fixture(%{
        company: company,
        master_unit: battle_armor
      })

      # Reload company
      company = Aces.Companies.get_company!(company.id)

      attrs = %{
        company_id: company.id,
        master_unit_id: battle_armor.id
      }

      changeset = CompanyUnit.draft_company_changeset(%CompanyUnit{}, attrs)
      assert changeset.valid?
    end

    test "prevents third identical unit", %{company: company, battle_armor: battle_armor} do
      # Add first two units
      CompaniesFixtures.company_unit_fixture(%{
        company: company,
        master_unit: battle_armor
      })

      CompaniesFixtures.company_unit_fixture(%{
        company: company,
        master_unit: battle_armor
      })

      # Reload company
      company = Aces.Companies.get_company!(company.id)

      attrs = %{
        company_id: company.id,
        master_unit_id: battle_armor.id
      }

      changeset = CompanyUnit.draft_company_changeset(%CompanyUnit{}, attrs)
      refute changeset.valid?
      assert "Cannot add more than 2 identical units of the same type" in errors_on(changeset).master_unit_id
    end
  end
end
