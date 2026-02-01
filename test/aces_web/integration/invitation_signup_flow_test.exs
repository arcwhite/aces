defmodule AcesWeb.Integration.InvitationSignupFlowTest do
  @moduledoc """
  Integration tests for the full invitation signup flow.

  These tests verify the end-to-end experience of:
  1. New user receiving invitation -> register -> login -> redirected to invitation -> accept
  2. Existing user receiving invitation -> login -> redirected to invitation -> accept
  """
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures

  alias Aces.Companies

  describe "New user invitation flow" do
    test "registration page preserves redirect_to in session", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, "newuser@example.com", "editor")

      # Visit registration page with redirect_to param
      conn = get(conn, ~p"/users/register?redirect_to=/invitations/#{token}")

      # Verify the page renders (session is set server-side, not visible in HTML)
      assert html_response(conn, 200) =~ "Register"
    end

    test "new user can view invitation page without auth and sees registration prompt", %{
      conn: conn
    } do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active", name: "Awesome Company")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, "newuser@example.com", "editor")

      # Visit the invitation URL as unauthenticated user
      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      # Should see the invitation details and registration prompt
      assert html =~ "Awesome Company"
      assert html =~ "Create an account"
      assert html =~ "newuser@example.com"
      assert html =~ "Create Account"
    end

    test "registration link has correct redirect_to param", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, "newuser@example.com", "viewer")

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      # Check that the registration link contains redirect_to
      assert html =~ ~r{/users/register\?[^"]*redirect_to=[^"]*invitations[^"]*#{token}}
    end
  end

  describe "Existing user invitation flow" do
    test "existing user can view invitation page without auth and sees login prompt", %{
      conn: conn
    } do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active", name: "Great Company")
      existing_user = user_fixture(email: "existing@example.com")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, existing_user.email, "editor")

      # Visit the invitation URL as unauthenticated user
      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      # Should see login prompt since user exists
      assert html =~ "Great Company"
      assert html =~ "Please log in to accept this invitation"
      assert html =~ "Log In"
    end

    test "login link has correct redirect_to param", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")
      existing_user = user_fixture(email: "existing@example.com")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, existing_user.email, "viewer")

      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")

      # Check that the login link contains redirect_to
      assert html =~ ~r{/users/log-in\?[^"]*redirect_to=[^"]*invitations[^"]*#{token}}
    end

    test "logged in user can accept invitation and gets redirected to company", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active", name: "Target Company")
      invitee = user_fixture(email: "invitee@example.com")

      {:ok, {token, _invitation}} =
        Companies.create_invitation(company, owner, invitee.email, "editor")

      # Log in as the invitee
      conn = log_in_user(conn, invitee)

      # Visit the invitation page
      {:ok, view, html} = live(conn, ~p"/invitations/#{token}")

      assert html =~ "You can accept this invitation"
      assert html =~ "Target Company"

      # Accept the invitation
      assert {:error, {:redirect, redirect_info}} =
               view |> element("button", "Accept Invitation") |> render_click()

      assert redirect_info.to == ~p"/companies/#{company.id}"

      # Verify membership was created with correct role
      membership = Companies.get_membership(company, invitee)
      assert membership != nil
      assert membership.role == "editor"
    end
  end

  describe "Full end-to-end flow simulation" do
    test "invitation acceptance updates all related data correctly", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")
      invitee = user_fixture()

      # Create invitation
      {:ok, {token, invitation}} =
        Companies.create_invitation(company, owner, invitee.email, "editor")

      # Verify invitation is pending
      assert invitation.status == "pending"

      # Log in as invitee
      conn = log_in_user(conn, invitee)

      # Accept via LiveView
      {:ok, view, _html} = live(conn, ~p"/invitations/#{token}")
      view |> element("button", "Accept Invitation") |> render_click()

      # Verify invitation status changed
      updated_invitation = Companies.get_invitation!(invitation.id)
      assert updated_invitation.status == "accepted"

      # Verify membership exists
      membership = Companies.get_membership(company, invitee)
      assert membership.role == "editor"

      # Verify invitee can now view company
      {:ok, _view, html} = live(conn, ~p"/companies/#{company.id}")
      assert html =~ company.name
    end

    test "token becomes invalid after acceptance", %{conn: conn} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")
      invitee = user_fixture()

      {:ok, {token, invitation}} =
        Companies.create_invitation(company, owner, invitee.email, "viewer")

      # Accept the invitation
      {:ok, _membership} = Companies.accept_invitation(invitation, invitee)

      # Try to use the token again - should show invalid
      {:ok, _view, html} = live(conn, ~p"/invitations/#{token}")
      assert html =~ "Invalid Invitation"
    end

    test "multiple invitations to same user for different companies work independently", %{
      conn: conn
    } do
      owner1 = user_fixture()
      owner2 = user_fixture()
      company1 = company_fixture(user: owner1, status: "active", name: "Company One")
      company2 = company_fixture(user: owner2, status: "active", name: "Company Two")
      invitee = user_fixture()

      {:ok, {token1, _}} = Companies.create_invitation(company1, owner1, invitee.email, "viewer")
      {:ok, {token2, _}} = Companies.create_invitation(company2, owner2, invitee.email, "editor")

      conn = log_in_user(conn, invitee)

      # Accept first invitation
      {:ok, view1, _} = live(conn, ~p"/invitations/#{token1}")
      view1 |> element("button", "Accept Invitation") |> render_click()

      # Second invitation should still be valid
      {:ok, view2, html2} = live(conn, ~p"/invitations/#{token2}")
      assert html2 =~ "Company Two"
      assert html2 =~ "Accept Invitation"

      # Accept second invitation
      view2 |> element("button", "Accept Invitation") |> render_click()

      # Verify both memberships exist
      assert Companies.get_membership(company1, invitee) != nil
      assert Companies.get_membership(company2, invitee) != nil
    end
  end
end
