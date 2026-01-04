defmodule Aces.Companies.AuthorizationTest do
  use Aces.DataCase

  alias Aces.Companies.Authorization

  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures

  describe "can?/3 for company listing" do
    test "any authenticated user can list companies" do
      user = user_fixture()
      assert Authorization.can?(:list_companies, user, nil)
    end

    test "any authenticated user can create a company" do
      user = user_fixture()
      assert Authorization.can?(:create_company, user, nil)
    end
  end

  describe "can?/3 for viewing companies" do
    test "owner can view company" do
      %{company: company, owner: owner} = company_with_members_fixture()
      assert Authorization.can?(:view_company, owner, company)
    end

    test "editor can view company" do
      %{company: company, editor: editor} = company_with_members_fixture()
      assert Authorization.can?(:view_company, editor, company)
    end

    test "viewer can view company" do
      %{company: company, viewer: viewer} = company_with_members_fixture()
      assert Authorization.can?(:view_company, viewer, company)
    end

    test "non-member cannot view company" do
      company = company_fixture()
      other_user = user_fixture()

      refute Authorization.can?(:view_company, other_user, company)
    end
  end

  describe "can?/3 for editing companies" do
    test "owner can edit company" do
      %{company: company, owner: owner} = company_with_members_fixture()
      assert Authorization.can?(:edit_company, owner, company)
    end

    test "editor can edit company" do
      %{company: company, editor: editor} = company_with_members_fixture()
      assert Authorization.can?(:edit_company, editor, company)
    end

    test "viewer cannot edit company" do
      %{company: company, viewer: viewer} = company_with_members_fixture()
      refute Authorization.can?(:edit_company, viewer, company)
    end

    test "non-member cannot edit company" do
      company = company_fixture()
      other_user = user_fixture()

      refute Authorization.can?(:edit_company, other_user, company)
    end
  end

  describe "can?/3 for deleting companies" do
    test "owner can delete company" do
      %{company: company, owner: owner} = company_with_members_fixture()
      assert Authorization.can?(:delete_company, owner, company)
    end

    test "editor cannot delete company" do
      %{company: company, editor: editor} = company_with_members_fixture()
      refute Authorization.can?(:delete_company, editor, company)
    end

    test "viewer cannot delete company" do
      %{company: company, viewer: viewer} = company_with_members_fixture()
      refute Authorization.can?(:delete_company, viewer, company)
    end

    test "non-member cannot delete company" do
      company = company_fixture()
      other_user = user_fixture()

      refute Authorization.can?(:delete_company, other_user, company)
    end
  end

  describe "can?/3 for managing members" do
    test "owner can manage members" do
      %{company: company, owner: owner} = company_with_members_fixture()
      assert Authorization.can?(:manage_members, owner, company)
    end

    test "editor cannot manage members" do
      %{company: company, editor: editor} = company_with_members_fixture()
      refute Authorization.can?(:manage_members, editor, company)
    end

    test "viewer cannot manage members" do
      %{company: company, viewer: viewer} = company_with_members_fixture()
      refute Authorization.can?(:manage_members, viewer, company)
    end
  end

  describe "can?/3 for adding units" do
    test "owner can add units" do
      %{company: company, owner: owner} = company_with_members_fixture()
      assert Authorization.can?(:add_units, owner, company)
    end

    test "editor can add units" do
      %{company: company, editor: editor} = company_with_members_fixture()
      assert Authorization.can?(:add_units, editor, company)
    end

    test "viewer cannot add units" do
      %{company: company, viewer: viewer} = company_with_members_fixture()
      refute Authorization.can?(:add_units, viewer, company)
    end
  end

  describe "can?/3 for removing units" do
    test "owner can remove units" do
      %{company: company, owner: owner} = company_with_members_fixture()
      assert Authorization.can?(:remove_units, owner, company)
    end

    test "editor can remove units" do
      %{company: company, editor: editor} = company_with_members_fixture()
      assert Authorization.can?(:remove_units, editor, company)
    end

    test "viewer cannot remove units" do
      %{company: company, viewer: viewer} = company_with_members_fixture()
      refute Authorization.can?(:remove_units, viewer, company)
    end
  end

  describe "can?/3 default deny" do
    test "returns false for unknown actions" do
      user = user_fixture()
      company = company_fixture()

      refute Authorization.can?(:unknown_action, user, company)
    end
  end
end
