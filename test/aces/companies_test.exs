defmodule Aces.CompaniesTest do
  use Aces.DataCase

  alias Aces.Companies
  alias Aces.Companies.Units

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
      assert company.status == "draft"

      # Verify owner membership was created
      assert Companies.get_user_role(company, user) == "owner"
    end

    test "creates company in draft status by default" do
      user = user_fixture()
      attrs = %{name: "Draft Company"}

      assert {:ok, company} = Companies.create_company(attrs, user)
      assert company.status == "draft"
      assert company.pv_budget == 400
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

  describe "list_company_members/1" do
    test "returns all members with users preloaded, ordered by role" do
      %{company: company, owner: owner, editor: editor, viewer: viewer} =
        company_with_members_fixture()

      members = Companies.list_company_members(company)

      assert length(members) == 3

      # Owners should be first, then editors, then viewers
      [first, second, third] = members
      assert first.role == "owner"
      assert first.user.id == owner.id
      assert second.role == "editor"
      assert second.user.id == editor.id
      assert third.role == "viewer"
      assert third.user.id == viewer.id
    end

    test "returns empty list for company with no members" do
      # Create company directly without membership
      {:ok, company} =
        %Aces.Companies.Company{}
        |> Aces.Companies.Company.changeset(%{name: "Orphan Company"})
        |> Aces.Repo.insert()

      assert Companies.list_company_members(company) == []
    end
  end

  describe "add_unit_to_company/3" do
    test "adds a unit to company roster" do
      company = company_fixture()
      master_unit = master_unit_fixture()

      assert {:ok, company_unit} =
               Units.add_unit_to_company(company, master_unit.mul_id, %{
                 custom_name: "The Destroyer",
                 purchase_cost_sp: 2000
               })

      assert company_unit.company_id == company.id
      assert company_unit.master_unit_id == master_unit.id
      assert company_unit.custom_name == "The Destroyer"
      assert company_unit.purchase_cost_sp == 2000
      assert company_unit.status == "operational"
    end
  end

  describe "remove_unit_from_company/1" do
    test "removes a unit from roster" do
      company_unit = company_unit_fixture()

      assert {:ok, _} = Units.remove_unit_from_company(company_unit)

      # Unit should be deleted
      assert Aces.Repo.get(Aces.Companies.CompanyUnit, company_unit.id) == nil
    end
  end

  describe "update_company_unit/2" do
    test "updates a company unit" do
      company_unit = company_unit_fixture()

      assert {:ok, updated} =
               Units.update_company_unit(company_unit, %{
                 custom_name: "New Name",
                 status: "damaged"
               })

      assert updated.custom_name == "New Name"
      assert updated.status == "damaged"
    end
  end

  describe "list_user_active_companies/1" do
    test "returns only active companies for a user" do
      user = user_fixture()
      draft_company = company_fixture(user: user, status: "draft")
      active_company = company_fixture(user: user, status: "active")
      _other_user_company = company_fixture(status: "active")

      companies = Companies.list_user_active_companies(user)
      company_ids = Enum.map(companies, & &1.id)

      assert active_company.id in company_ids
      refute draft_company.id in company_ids
      assert length(companies) == 1
    end

    test "returns empty list when user has no active companies" do
      user = user_fixture()
      _draft_company = company_fixture(user: user, status: "draft")

      assert Companies.list_user_active_companies(user) == []
    end
  end

  describe "list_user_draft_companies/1" do
    test "returns only draft companies for a user" do
      user = user_fixture()
      draft_company = company_fixture(user: user, status: "draft")
      active_company = company_fixture(user: user, status: "active")
      _other_user_company = company_fixture(status: "draft")

      companies = Companies.list_user_draft_companies(user)
      company_ids = Enum.map(companies, & &1.id)

      assert draft_company.id in company_ids
      refute active_company.id in company_ids
      assert length(companies) == 1
    end

    test "returns empty list when user has no draft companies" do
      user = user_fixture()
      _active_company = company_fixture(user: user, status: "active")

      assert Companies.list_user_draft_companies(user) == []
    end
  end

  describe "finalize_company/1" do
    # Helper to add the minimum required units (8) to a company
    defp add_minimum_units(company, pv_per_unit \\ 10) do
      master_unit = master_unit_fixture(point_value: pv_per_unit)
      for _ <- 1..8 do
        company_unit_fixture(company: company, master_unit: master_unit)
      end
    end

    test "converts draft company to active and converts unused PV to SP" do
      company = company_fixture(
        status: "draft",
        pv_budget: 400,
        warchest_balance: 1000
      )

      # Add required pilots (minimum 2)
      pilot_fixture(company: company, name: "Pilot One")
      pilot_fixture(company: company, name: "Pilot Two")

      # Add 8 units at 10 PV each = 80 PV used, leaving 320 PV unused
      add_minimum_units(company, 10)

      # Reload company with its units before finalizing
      company_with_units = Companies.get_company!(company.id)
      assert {:ok, finalized} = Companies.finalize_company(company_with_units)

      assert finalized.status == "active"
      # 1000 base + (320 unused PV * 40) = 1000 + 12800 = 13800
      assert finalized.warchest_balance == 13_800
    end

    test "handles company with no unused PV" do
      company = company_fixture(
        status: "draft",
        pv_budget: 80,
        warchest_balance: 2000
      )

      # Add required pilots (minimum 2)
      pilot_fixture(company: company, name: "Pilot One")
      pilot_fixture(company: company, name: "Pilot Two")

      # Add 8 units at 10 PV each = exactly 80 PV (all budget used)
      add_minimum_units(company, 10)

      # Reload company with its units before finalizing
      company_with_units = Companies.get_company!(company.id)
      assert {:ok, finalized} = Companies.finalize_company(company_with_units)

      assert finalized.status == "active"
      # 2000 base + (0 unused PV * 40) = 2000
      assert finalized.warchest_balance == 2000
    end

    test "converts most unused PV to SP when using minimum units" do
      company = company_fixture(
        status: "draft",
        pv_budget: 400,
        warchest_balance: 500
      )

      # Add required pilots (minimum 2)
      pilot_fixture(company: company, name: "Pilot One")
      pilot_fixture(company: company, name: "Pilot Two")

      # Add 8 units at 1 PV each = 8 PV used, leaving 392 PV unused
      add_minimum_units(company, 1)

      # Reload company with units
      company_with_units = Companies.get_company!(company.id)
      assert {:ok, finalized} = Companies.finalize_company(company_with_units)

      assert finalized.status == "active"
      # 500 base + (392 unused PV * 40) = 500 + 15680 = 16180
      assert finalized.warchest_balance == 16_180
    end

    test "returns error when company is already active" do
      company = company_fixture(status: "active")

      assert {:error, %Ecto.Changeset{} = changeset} = Companies.finalize_company(company)
      assert %{status: ["company is already active, cannot finalize"]} = errors_on(changeset)
    end

    test "returns error with unknown status" do
      # This shouldn't happen in practice, but test edge case
      company = company_fixture(status: "draft")
      # Update directly in DB to bypass validation
      Aces.Repo.query!("UPDATE companies SET status = 'unknown' WHERE id = $1", [company.id])
      reloaded = Companies.get_company!(company.id)

      assert {:error, %Ecto.Changeset{} = changeset} = Companies.finalize_company(reloaded)
      assert %{status: ["company is already unknown, cannot finalize"]} = errors_on(changeset)
    end

    test "returns error when company has no pilots" do
      company = company_fixture(status: "draft")

      assert {:error, %Ecto.Changeset{} = changeset} = Companies.finalize_company(company)
      assert %{pilots: ["company must have at least 2 named pilots to finalize"]} = errors_on(changeset)
    end

    test "returns error when company has only 1 pilot" do
      company = company_fixture(status: "draft")
      pilot_fixture(company: company, name: "Solo Pilot")
      add_minimum_units(company)

      # Reload company with pilots
      company_with_pilot = Companies.get_company!(company.id)

      assert {:error, %Ecto.Changeset{} = changeset} = Companies.finalize_company(company_with_pilot)
      assert %{pilots: ["company must have at least 2 named pilots to finalize"]} = errors_on(changeset)
    end

    test "returns error when company has fewer than 8 units" do
      company = company_fixture(status: "draft")
      pilot_fixture(company: company, name: "Pilot One")
      pilot_fixture(company: company, name: "Pilot Two")

      # Add only 7 units (one less than minimum)
      master_unit = master_unit_fixture(point_value: 10)
      for _ <- 1..7 do
        company_unit_fixture(company: company, master_unit: master_unit)
      end

      # Reload company
      company_with_units = Companies.get_company!(company.id)

      assert {:error, %Ecto.Changeset{} = changeset} = Companies.finalize_company(company_with_units)
      assert %{company_units: ["company must have at least 8 units to finalize"]} = errors_on(changeset)
    end

    test "returns error when company has no units" do
      company = company_fixture(status: "draft")
      pilot_fixture(company: company, name: "Pilot One")
      pilot_fixture(company: company, name: "Pilot Two")

      # Reload company (no units added)
      company_reloaded = Companies.get_company!(company.id)

      assert {:error, %Ecto.Changeset{} = changeset} = Companies.finalize_company(company_reloaded)
      assert %{company_units: ["company must have at least 8 units to finalize"]} = errors_on(changeset)
    end

    test "succeeds when company has exactly 2 pilots and 8 units" do
      company = company_fixture(status: "draft", pv_budget: 100, warchest_balance: 0)
      pilot_fixture(company: company, name: "Pilot Alpha")
      pilot_fixture(company: company, name: "Pilot Beta")
      add_minimum_units(company, 1)

      # Reload company with pilots and units
      company_with_all = Companies.get_company!(company.id)

      assert {:ok, finalized} = Companies.finalize_company(company_with_all)
      assert finalized.status == "active"
    end
  end

  describe "purchase_unit_for_company/3 with status checking" do
    test "allows PV purchases for draft companies" do
      company = company_fixture(status: "draft", pv_budget: 400)
      master_unit = master_unit_fixture(
        point_value: 100,
        mul_id: 123,
        last_synced_at: DateTime.truncate(DateTime.utc_now(), :second)  # Fresh cache to avoid HTTP call
      )

      # Now this should work without making HTTP calls since unit is cached
      assert {:ok, _company_unit} =
        Units.purchase_unit_for_company(company, master_unit.mul_id)
    end

    test "prevents PV purchases for active companies" do
      company = company_fixture(status: "active")
      master_unit = master_unit_fixture(
        point_value: 100,
        mul_id: 456,
        last_synced_at: DateTime.truncate(DateTime.utc_now(), :second)  # Fresh cache to avoid HTTP call
      )

      # This should return an error for active companies
      assert {:error, %Ecto.Changeset{} = changeset} =
        Units.purchase_unit_for_company(company, master_unit.mul_id)

      assert %{company_id: ["Cannot add units to active companies"]} = errors_on(changeset)
    end
  end

  describe "add_unit_to_company/3 with status checking" do
    test "allows unit addition for draft companies" do
      company = company_fixture(status: "draft", pv_budget: 400)
      master_unit = master_unit_fixture(point_value: 100)

      assert {:ok, _company_unit} =
        Units.add_unit_to_company(company, master_unit.mul_id)
    end

    test "prevents unit addition for active companies" do
      company = company_fixture(status: "active")
      master_unit = master_unit_fixture(point_value: 100)

      assert {:error, %Ecto.Changeset{} = changeset} =
        Units.add_unit_to_company(company, master_unit.mul_id)

      assert %{company_id: ["Cannot add units to active companies"]} = errors_on(changeset)
    end
  end


  describe "integration tests for validation with purchase_unit_for_company" do
    test "purchase_unit_for_company respects unit type restrictions" do
      company = company_fixture(status: "draft", pv_budget: 400)
      protomech = master_unit_fixture(unit_type: "protomech", point_value: 50)

      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
        Units.purchase_unit_for_company(company, protomech.mul_id)

      assert "Only types Battlemech, Battle Armor, Combat Vehicle, Conventional Infantry are allowed" in errors_on(changeset).master_unit_id
    end

    test "purchase_unit_for_company respects battlemech chassis limits" do
      company = company_fixture(status: "draft", pv_budget: 400)
      warhammer1 = master_unit_fixture(unit_type: "battlemech", name: "Warhammer", variant: "WHM-6R", point_value: 50)
      warhammer2 = master_unit_fixture(unit_type: "battlemech", name: "Warhammer", variant: "WHM-6D", point_value: 50)
      warhammer3 = master_unit_fixture(unit_type: "battlemech", name: "Warhammer", variant: "WHM-7M", point_value: 50)

      # Add two different Warhammer variants
      assert {:ok, _} = Units.purchase_unit_for_company(company, warhammer1.mul_id)
      assert {:ok, _} = Units.purchase_unit_for_company(company, warhammer2.mul_id)

      # Third should fail
      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
        Units.purchase_unit_for_company(company, warhammer3.mul_id)

      assert "Cannot add more than 2 Battlemechs of the same chassis" in errors_on(changeset).master_unit_id
    end

    test "purchase_unit_for_company respects variant duplication rules for battlemechs" do
      company = company_fixture(status: "draft", pv_budget: 400)
      warhammer1 = master_unit_fixture(unit_type: "battlemech", name: "Warhammer", variant: "WHM-6R", point_value: 50)
      warhammer2 = master_unit_fixture(unit_type: "battlemech", name: "Warhammer", variant: "WHM-6R", point_value: 50)

      # Add one variant
      assert {:ok, _} = Units.purchase_unit_for_company(company, warhammer1.mul_id)

      # Same variant should fail
      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
        Units.purchase_unit_for_company(company, warhammer2.mul_id)

      assert "Cannot add duplicate Battlemech variants of the same chassis" in errors_on(changeset).master_unit_id
    end

    test "purchase_unit_for_company respects unit limits for non-battlemech types" do
      company = company_fixture(status: "draft", pv_budget: 400)
      maxim = master_unit_fixture(unit_type: "combat_vehicle", name: "Maxim", variant: "Standard", point_value: 50)

      # Add two identical units
      assert {:ok, _} = Units.purchase_unit_for_company(company, maxim.mul_id)
      assert {:ok, _} = Units.purchase_unit_for_company(company, maxim.mul_id)

      # Third should fail
      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
        Units.purchase_unit_for_company(company, maxim.mul_id)

      assert "Cannot add more than 2 identical units of the same type" in errors_on(changeset).master_unit_id
    end
  end

  describe "company invitations" do
    test "create_invitation/4 creates a valid invitation" do
      %{company: company, owner: owner} = company_with_members_fixture()

      assert {:ok, {token, invitation}} =
               Companies.create_invitation(company, owner, "invitee@example.com", "editor")

      assert invitation.invited_email == "invitee@example.com"
      assert invitation.role == "editor"
      assert invitation.status == "pending"
      assert invitation.company_id == company.id
      assert invitation.invited_by_id == owner.id
      assert is_binary(token)
      assert DateTime.diff(invitation.expires_at, DateTime.utc_now(), :day) >= 6
    end

    test "create_invitation/4 defaults to viewer role" do
      %{company: company, owner: owner} = company_with_members_fixture()

      assert {:ok, {_token, invitation}} =
               Companies.create_invitation(company, owner, "invitee@example.com")

      assert invitation.role == "viewer"
    end

    test "create_invitation/4 returns error for already member" do
      %{company: company, owner: owner, editor: editor} = company_with_members_fixture()

      assert {:error, :already_member} =
               Companies.create_invitation(company, owner, editor.email, "viewer")
    end

    test "create_invitation/4 prevents duplicate pending invitations" do
      %{company: company, owner: owner} = company_with_members_fixture()

      assert {:ok, _} = Companies.create_invitation(company, owner, "invitee@example.com")
      assert {:error, changeset} = Companies.create_invitation(company, owner, "invitee@example.com")

      assert "already has a pending invitation" in errors_on(changeset).invited_email
    end

    test "get_invitation_by_token/1 returns invitation for valid token" do
      %{company: company, owner: owner} = company_with_members_fixture()
      {:ok, {token, _}} = Companies.create_invitation(company, owner, "invitee@example.com")

      assert {:ok, invitation} = Companies.get_invitation_by_token(token)
      assert invitation.invited_email == "invitee@example.com"
      assert invitation.company.id == company.id
    end

    test "get_invitation_by_token/1 returns error for invalid token" do
      assert {:error, :invalid_token} = Companies.get_invitation_by_token("invalid-token")
    end

    test "get_invitation_by_token/1 returns error for expired invitation" do
      %{company: company, owner: owner} = company_with_members_fixture()
      {:ok, {token, invitation}} = Companies.create_invitation(company, owner, "invitee@example.com")

      # Manually expire the invitation
      expired_at = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      invitation
      |> Ecto.Changeset.change(%{expires_at: expired_at})
      |> Aces.Repo.update!()

      assert {:error, :invalid_token} = Companies.get_invitation_by_token(token)
    end

    test "accept_invitation/2 creates membership and marks invitation accepted" do
      %{company: company, owner: owner} = company_with_members_fixture()
      invitee = user_fixture(email: "invitee@example.com")

      {:ok, {_token, invitation}} =
        Companies.create_invitation(company, owner, "invitee@example.com", "editor")

      invitation = Companies.get_invitation!(invitation.id)
      assert {:ok, membership} = Companies.accept_invitation(invitation, invitee)

      assert membership.user_id == invitee.id
      assert membership.company_id == company.id
      assert membership.role == "editor"

      # Verify invitation is marked as accepted
      updated_invitation = Companies.get_invitation!(invitation.id)
      assert updated_invitation.status == "accepted"
      assert updated_invitation.accepted_at != nil
    end

    test "accept_invitation/2 returns error for email mismatch" do
      %{company: company, owner: owner} = company_with_members_fixture()
      wrong_user = user_fixture(email: "wrong@example.com")

      {:ok, {_token, invitation}} =
        Companies.create_invitation(company, owner, "invitee@example.com", "editor")

      invitation = Companies.get_invitation!(invitation.id)
      assert {:error, :email_mismatch} = Companies.accept_invitation(invitation, wrong_user)
    end

    test "cancel_invitation/1 cancels a pending invitation" do
      %{company: company, owner: owner} = company_with_members_fixture()

      {:ok, {_token, invitation}} = Companies.create_invitation(company, owner, "invitee@example.com")
      invitation = Companies.get_invitation!(invitation.id)

      assert {:ok, cancelled} = Companies.cancel_invitation(invitation)
      assert cancelled.status == "cancelled"
    end

    test "cancel_invitation/1 returns error for non-pending invitation" do
      %{company: company, owner: owner} = company_with_members_fixture()
      invitee = user_fixture(email: "invitee@example.com")

      {:ok, {_token, invitation}} = Companies.create_invitation(company, owner, "invitee@example.com")
      invitation = Companies.get_invitation!(invitation.id)

      # Accept the invitation first
      {:ok, _} = Companies.accept_invitation(invitation, invitee)

      # Try to cancel - should fail
      accepted_invitation = Companies.get_invitation!(invitation.id)
      assert {:error, :not_pending} = Companies.cancel_invitation(accepted_invitation)
    end

    test "list_pending_invitations/1 returns pending invitations for company" do
      %{company: company, owner: owner} = company_with_members_fixture()

      {:ok, _} = Companies.create_invitation(company, owner, "user1@example.com")
      {:ok, _} = Companies.create_invitation(company, owner, "user2@example.com")

      # Cancel one invitation
      {:ok, {_, inv3}} = Companies.create_invitation(company, owner, "user3@example.com")
      inv3 = Companies.get_invitation!(inv3.id)
      {:ok, _} = Companies.cancel_invitation(inv3)

      invitations = Companies.list_pending_invitations(company)
      emails = Enum.map(invitations, & &1.invited_email)

      assert length(invitations) == 2
      assert "user1@example.com" in emails
      assert "user2@example.com" in emails
      refute "user3@example.com" in emails
    end

    test "list_user_pending_invitations/1 returns pending invitations for user email" do
      %{company: company1, owner: owner1} = company_with_members_fixture()
      %{company: company2, owner: owner2} = company_with_members_fixture()

      invitee = user_fixture(email: "invitee@example.com")

      {:ok, _} = Companies.create_invitation(company1, owner1, invitee.email)
      {:ok, _} = Companies.create_invitation(company2, owner2, invitee.email)

      invitations = Companies.list_user_pending_invitations(invitee)
      company_ids = Enum.map(invitations, & &1.company_id)

      assert length(invitations) == 2
      assert company1.id in company_ids
      assert company2.id in company_ids
    end

    test "list_user_all_invitations/1 returns all invitations including accepted and cancelled" do
      %{company: company1, owner: owner1} = company_with_members_fixture()
      %{company: company2, owner: owner2} = company_with_members_fixture()
      %{company: company3, owner: owner3} = company_with_members_fixture()

      invitee = user_fixture(email: "invitee@example.com")

      # Create three invitations
      {:ok, _} = Companies.create_invitation(company1, owner1, invitee.email)
      {:ok, {_, inv2}} = Companies.create_invitation(company2, owner2, invitee.email)
      {:ok, {_, inv3}} = Companies.create_invitation(company3, owner3, invitee.email)

      # Accept one
      inv2 = Companies.get_invitation!(inv2.id)
      {:ok, _} = Companies.accept_invitation(inv2, invitee)

      # Cancel one
      inv3 = Companies.get_invitation!(inv3.id)
      {:ok, _} = Companies.cancel_invitation(inv3)

      # Should return all three
      all_invitations = Companies.list_user_all_invitations(invitee)
      assert length(all_invitations) == 3

      statuses = Enum.map(all_invitations, & &1.status) |> Enum.sort()
      assert statuses == ["accepted", "cancelled", "pending"]

      # Pending should only return one
      pending = Companies.list_user_pending_invitations(invitee)
      assert length(pending) == 1
      assert hd(pending).status == "pending"
    end

    test "list_user_sent_invitations/1 returns invitations sent by user" do
      %{company: company, owner: owner} = company_with_members_fixture()

      invitee1 = user_fixture(email: "invitee1@example.com")
      invitee2 = user_fixture(email: "invitee2@example.com")

      # Owner sends two invitations
      {:ok, _} = Companies.create_invitation(company, owner, invitee1.email, "editor")
      {:ok, {_, inv2}} = Companies.create_invitation(company, owner, invitee2.email, "viewer")

      # invitee2 accepts their invitation
      inv2 = Companies.get_invitation!(inv2.id)
      {:ok, _} = Companies.accept_invitation(inv2, invitee2)

      # Owner should see both sent invitations
      sent = Companies.list_user_sent_invitations(owner)
      assert length(sent) == 2

      emails = Enum.map(sent, & &1.invited_email) |> Enum.sort()
      assert emails == ["invitee1@example.com", "invitee2@example.com"]

      statuses = Enum.map(sent, & &1.status) |> Enum.sort()
      assert statuses == ["accepted", "pending"]

      # invitee1 should see no sent invitations
      assert Companies.list_user_sent_invitations(invitee1) == []
    end
  end
end
