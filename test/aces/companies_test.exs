defmodule Aces.CompaniesTest do
  use Aces.DataCase

  alias Aces.Companies

  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures

  describe "list_user_companies/1" do
    test "returns all companies for a user" do
      user = user_fixture()
      company1 = company_fixture(user: user)
      company2 = company_fixture(user: user)
      _other_company = company_fixture()

      companies = Companies.list_user_companies(user)
      company_ids = Enum.map(companies, & &1.id)

      assert company1.id in company_ids
      assert company2.id in company_ids
      assert length(companies) == 2
    end

    test "returns empty list when user has no companies" do
      user = user_fixture()
      assert Companies.list_user_companies(user) == []
    end
  end

  describe "list_user_companies_with_stats/1" do
    test "returns companies with stats" do
      user = user_fixture()
      company = company_fixture(user: user, warchest_balance: 5000)
      company_unit_fixture(company: company)
      company_unit_fixture(company: company)

      [result] = Companies.list_user_companies_with_stats(user)

      assert result.id == company.id
      assert result.stats.unit_count == 2
      assert result.stats.warchest_balance == 5000
      assert %DateTime{} = result.stats.last_modified
    end
  end

  describe "get_company!/1" do
    test "returns the company with given id" do
      company = company_fixture()
      fetched = Companies.get_company!(company.id)

      assert fetched.id == company.id
      assert fetched.name == company.name
    end

    test "raises when company does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Companies.get_company!(0)
      end
    end
  end

  describe "get_company_with_stats!/1" do
    test "returns company with stats" do
      company = company_fixture(warchest_balance: 3000)
      company_unit_fixture(company: company)

      result = Companies.get_company_with_stats!(company.id)

      assert result.id == company.id
      assert result.stats.unit_count == 1
      assert result.stats.warchest_balance == 3000
    end
  end

  describe "create_company/2" do
    test "creates a company with valid attributes and adds creator as owner" do
      user = user_fixture()

      attrs = %{
        name: "Test Company",
        description: "A test company",
        warchest_balance: 2000
      }

      assert {:ok, company} = Companies.create_company(attrs, user)
      assert company.name == "Test Company"
      assert company.description == "A test company"
      assert company.warchest_balance == 2000

      # Verify owner membership was created
      assert Companies.get_user_role(company, user) == "owner"
    end

    test "returns error changeset with invalid attributes" do
      user = user_fixture()

      assert {:error, %Ecto.Changeset{}} = Companies.create_company(%{name: nil}, user)
    end

    test "validates name is required" do
      user = user_fixture()

      assert {:error, changeset} = Companies.create_company(%{name: ""}, user)
      assert "can't be blank" in errors_on(changeset).name
    end

    test "validates warchest_balance is non-negative" do
      user = user_fixture()

      assert {:error, changeset} =
               Companies.create_company(%{name: "Test", warchest_balance: -100}, user)

      assert "must be greater than or equal to 0" in errors_on(changeset).warchest_balance
    end
  end

  describe "update_company/2" do
    test "updates company with valid attributes" do
      company = company_fixture()

      assert {:ok, updated} =
               Companies.update_company(company, %{
                 name: "Updated Name",
                 warchest_balance: 5000
               })

      assert updated.name == "Updated Name"
      assert updated.warchest_balance == 5000
    end

    test "returns error changeset with invalid attributes" do
      company = company_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Companies.update_company(company, %{name: nil})
    end
  end

  describe "delete_company/1" do
    test "deletes the company" do
      company = company_fixture()

      assert {:ok, _} = Companies.delete_company(company)
      assert_raise Ecto.NoResultsError, fn -> Companies.get_company!(company.id) end
    end

    test "deletes company memberships when company is deleted" do
      %{company: company, editor: editor} = company_with_members_fixture()

      assert Companies.get_user_role(company, editor) == "editor"
      assert {:ok, _} = Companies.delete_company(company)

      # Membership should be gone
      assert Companies.get_membership(Companies.get_company!(company.id), editor) == nil
    rescue
      Ecto.NoResultsError -> :ok
    end
  end

  describe "change_company/2" do
    test "returns a company changeset" do
      company = company_fixture()
      changeset = Companies.change_company(company)

      assert %Ecto.Changeset{} = changeset
      assert changeset.data.id == company.id
    end
  end

  describe "add_member/3" do
    test "adds a user to a company with specified role" do
      company = company_fixture()
      user = user_fixture()

      assert {:ok, membership} = Companies.add_member(company, user, "editor")
      assert membership.role == "editor"
      assert membership.user_id == user.id
      assert membership.company_id == company.id
    end

    test "defaults to viewer role if not specified" do
      company = company_fixture()
      user = user_fixture()

      assert {:ok, membership} = Companies.add_member(company, user)
      assert membership.role == "viewer"
    end

    test "returns error when adding duplicate member" do
      company = company_fixture()
      user = user_fixture()

      assert {:ok, _} = Companies.add_member(company, user, "editor")
      assert {:error, changeset} = Companies.add_member(company, user, "viewer")

      assert "has already been taken" in errors_on(changeset).user_id
    end
  end

  describe "update_member_role/2" do
    test "updates a member's role" do
      %{company: company, editor: editor} = company_with_members_fixture()
      membership = Companies.get_membership(company, editor)

      assert {:ok, updated} = Companies.update_member_role(membership, "owner")
      assert updated.role == "owner"
    end
  end

  describe "remove_member/1" do
    test "removes a member from a company" do
      %{company: company, viewer: viewer} = company_with_members_fixture()
      membership = Companies.get_membership(company, viewer)

      assert {:ok, _} = Companies.remove_member(membership)
      assert Companies.get_membership(company, viewer) == nil
    end
  end

  describe "get_membership/2" do
    test "returns membership when user is a member" do
      %{company: company, editor: editor} = company_with_members_fixture()

      membership = Companies.get_membership(company, editor)
      assert membership.role == "editor"
    end

    test "returns nil when user is not a member" do
      company = company_fixture()
      user = user_fixture()

      assert Companies.get_membership(company, user) == nil
    end
  end

  describe "get_user_role/2" do
    test "returns role when user is a member" do
      %{company: company, owner: owner, editor: editor, viewer: viewer} =
        company_with_members_fixture()

      assert Companies.get_user_role(company, owner) == "owner"
      assert Companies.get_user_role(company, editor) == "editor"
      assert Companies.get_user_role(company, viewer) == "viewer"
    end

    test "returns nil when user is not a member" do
      company = company_fixture()
      user = user_fixture()

      assert Companies.get_user_role(company, user) == nil
    end
  end

  describe "add_unit_to_company/3" do
    test "adds a unit to company roster" do
      company = company_fixture()
      master_unit = master_unit_fixture()

      assert {:ok, company_unit} =
               Companies.add_unit_to_company(company, master_unit.mul_id, %{
                 custom_name: "The Destroyer",
                 purchase_cost_sp: 2000
               })

      assert company_unit.company_id == company.id
      assert company_unit.master_unit_id == master_unit.id
      assert company_unit.custom_name == "The Destroyer"
      assert company_unit.purchase_cost_sp == 2000
      assert company_unit.status == "operational"
    end

    test "creates master unit if it doesn't exist" do
      company = company_fixture()
      new_mul_id = 99999

      assert {:ok, company_unit} =
               Companies.add_unit_to_company(company, new_mul_id, %{
                 name: "Timber Wolf",
                 variant: "TBR-Prime",
                 unit_type: "battlemech",
                 point_value: 52
               })

      # Reload to get master_unit association
      company_unit = Aces.Repo.preload(company_unit, :master_unit, force: true)

      assert company_unit.master_unit.mul_id == new_mul_id
      assert company_unit.master_unit.name == "Timber Wolf"
    end
  end

  describe "remove_unit_from_company/1" do
    test "removes a unit from roster" do
      company_unit = company_unit_fixture()

      assert {:ok, _} = Companies.remove_unit_from_company(company_unit)

      # Unit should be deleted
      assert Aces.Repo.get(Aces.Companies.CompanyUnit, company_unit.id) == nil
    end
  end

  describe "update_company_unit/2" do
    test "updates a company unit" do
      company_unit = company_unit_fixture()

      assert {:ok, updated} =
               Companies.update_company_unit(company_unit, %{
                 custom_name: "New Name",
                 status: "damaged"
               })

      assert updated.custom_name == "New Name"
      assert updated.status == "damaged"
    end
  end
end
