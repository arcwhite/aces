defmodule AcesWeb.InvitationLive.AcceptTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures

  alias Aces.Companies

  describe "Accept invitation page - invalid state" do
    test "shows invalid message for bad token", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invitations/invalid-token")

      assert html =~ "Invalid Invitation"
      assert html =~ "invalid, has expired, or has already been used"
    end

    test "shows invalid message for expired token", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")

      # Create invitation and manually expire it
      {:ok, {token, invitation}} =
        Companies.create_invitation(company, owner, "test@example.com", "viewer")

      # Expire the invitation (truncate to second precision for Ecto)
      expired_at =
        DateTime.utc_now()
        |> DateTime.add(-1, :day)
        |> DateTime.truncate(:second)

      invitation
      |> Ecto.Changeset.change(%{expires_at: expired_at})
      |> Aces.Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      assert html =~ "Invalid Invitation"
    end

    test "shows invalid message for already accepted token", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")
      invitee = user_fixture(email: "invitee@example.com")

      {:ok, {token, invitation}} =
        Companies.create_invitation(company, owner, "invitee@example.com", "viewer")

      # Accept the invitation
      {:ok, _membership} = Companies.accept_invitation(invitation, invitee)

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      assert html =~ "Invalid Invitation"
    end
  end

  describe "Accept invitation page - needs_login state" do
    test "shows login prompt for existing user not logged in", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")
      _existing_user = user_fixture(email: "existing@example.com")

      {:ok, {_token, _invitation}} =
        Companies.create_invitation(company, owner, "existing@example.com", "viewer")

      {:ok, _view, _html} = live(conn, ~p"/invitations/existing@example.com")

      # Will show invalid since that's not a valid token, so test with real token
      owner2 = user_fixture()
      company2 = company_fixture(user: owner2, status: "active")
      _user2 = user_fixture(email: "existing2@example.com")

      {:ok, {token2, _invitation2}} =
        Companies.create_invitation(company2, owner2, "existing2@example.com", "viewer")

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token2}")

      assert html =~ "Company Invitation"
      assert html =~ "Please log in to accept this invitation"
      assert html =~ "Log In"
      assert html =~ company2.name
    end

    test "login link includes redirect back to invitation", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")
      _existing_user = user_fixture(email: "existing@example.com")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, "existing@example.com", "viewer")

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      # The URL is encoded, so check for the encoded version
      assert html =~ "redirect_to="
      assert html =~ URI.encode_www_form("/invitations/#{token}")
    end
  end

  describe "Accept invitation page - needs_registration state" do
    test "shows registration prompt for new user", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, "newuser@example.com", "viewer")

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      assert html =~ "Company Invitation"
      assert html =~ "Create an account"
      assert html =~ "newuser@example.com"
      assert html =~ "Create Account"
      assert html =~ company.name
    end

    test "registration link includes redirect back to invitation", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, "newuser@example.com", "viewer")

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      # The URL is encoded, so check for the encoded version
      assert html =~ "redirect_to="
      assert html =~ URI.encode_www_form("/invitations/#{token}")
    end
  end

  describe "Accept invitation page - email_mismatch state" do
    setup :register_and_log_in_user

    test "shows mismatch warning when logged in with wrong email", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, "different@example.com", "viewer")

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      assert html =~ "Email mismatch"
      assert html =~ "different@example.com"
      assert html =~ "logged in with a different email"
    end

    test "provides logout option", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, "different@example.com", "viewer")

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      assert html =~ "Log out and use correct account"
    end
  end

  describe "Accept invitation page - can_accept state" do
    setup :register_and_log_in_user

    test "shows accept button when logged in with correct email", %{conn: conn, user: user} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, user.email, "editor")

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      assert html =~ "You can accept this invitation"
      assert html =~ "Accept Invitation"
      assert html =~ company.name
      assert html =~ "Role: Editor"
    end

    test "displays invitation details", %{conn: conn, user: user} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active", description: "A great company")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, user.email, "viewer")

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      assert html =~ company.name
      assert html =~ "A great company"
      assert html =~ "Role: Viewer"
      assert html =~ "Expires:"
      assert html =~ owner.email
    end

    test "accepting invitation creates membership and redirects", %{conn: conn, user: user} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, user.email, "editor")

      {:ok, view, _html} = live(conn, ~p"/invitations/#{token}")

      assert {:error, {:redirect, redirect_info}} =
               view |> element("button", "Accept Invitation") |> render_click()

      assert redirect_info.to == ~p"/companies/#{company.id}"

      # Verify membership was created with correct role
      membership = Companies.get_membership(company, user)
      assert membership != nil
      assert membership.role == "editor"
    end
  end
end
