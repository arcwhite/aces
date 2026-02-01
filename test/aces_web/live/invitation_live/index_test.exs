defmodule AcesWeb.InvitationLive.IndexTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures

  alias Aces.Companies

  setup :register_and_log_in_user

  describe "Invitations dashboard" do
    test "shows empty state when no invitations", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invitations")

      assert html =~ "Invitations"
      assert html =~ "Pending Invitations"
      # HTML-encoded apostrophe
      assert html =~ "any pending invitations"
      assert html =~ "sent any invitations"
    end

    test "displays pending invitations with accept/decline buttons", %{conn: conn, user: user} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active", name: "Test Company")

      {:ok, {_token, _invitation}} =
        Companies.create_invitation(company, owner, user.email, "editor")

      {:ok, _view, html} = live(conn, ~p"/invitations")

      assert html =~ "Test Company"
      assert html =~ "Role: Editor"
      assert html =~ "Accept Invitation"
      assert html =~ "Decline"
    end

    test "can accept invitation from dashboard", %{conn: conn, user: user} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active", name: "Test Company")

      {:ok, {_token, _invitation}} =
        Companies.create_invitation(company, owner, user.email, "viewer")

      {:ok, view, _html} = live(conn, ~p"/invitations")

      view |> element("button", "Accept Invitation") |> render_click()

      # Render to see the updated state
      html = render(view)

      # The invitation should move to history as accepted
      refute html =~ ~r/<button[^>]*>Accept Invitation<\/button>/
      assert html =~ "Accepted"

      # Verify membership was created
      membership = Companies.get_membership(company, user)
      assert membership != nil
    end

    test "can decline invitation from dashboard", %{conn: conn, user: user} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active", name: "Test Company")

      {:ok, {_token, _invitation}} =
        Companies.create_invitation(company, owner, user.email, "viewer")

      {:ok, view, _html} = live(conn, ~p"/invitations")

      view |> element("button", "Decline") |> render_click()

      # Render to see the updated state
      html = render(view)

      # The invitation should move to history as declined
      refute html =~ ~r/<button[^>]*>Accept Invitation<\/button>/
      assert html =~ "Declined"
    end

    test "displays sent invitations with cancel option", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active", name: "My Company")

      {:ok, {_token, _invitation}} =
        Companies.create_invitation(company, user, "newmember@example.com", "editor")

      {:ok, _view, html} = live(conn, ~p"/invitations")

      assert html =~ "Invitations Sent"
      assert html =~ "newmember@example.com"
      assert html =~ "My Company"
      assert html =~ "Editor"
      assert html =~ "Pending"
      assert html =~ "Cancel"
    end

    test "can cancel sent invitation", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active", name: "My Company")

      {:ok, {_token, _invitation}} =
        Companies.create_invitation(company, user, "newmember@example.com", "editor")

      {:ok, view, _html} = live(conn, ~p"/invitations")

      view |> element("button", "Cancel") |> render_click()

      # Render to see the updated state
      html = render(view)

      # The invitation should now show as Declined (cancelled)
      assert html =~ "Declined"
    end

    test "shows invitation history section when there's history", %{conn: conn, user: user} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active", name: "Past Company")

      # Create and accept an invitation
      {:ok, {_token, invitation}} =
        Companies.create_invitation(company, owner, user.email, "viewer")

      {:ok, _membership} = Companies.accept_invitation(invitation, user)

      {:ok, _view, html} = live(conn, ~p"/invitations")

      assert html =~ "Received History"
      assert html =~ "Past Company"
      assert html =~ "Accepted"
    end

    test "shows expired invitations in history", %{conn: conn, user: user} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active", name: "Expired Company")

      {:ok, {_token, invitation}} =
        Companies.create_invitation(company, owner, user.email, "viewer")

      # Expire the invitation (truncate to second precision for Ecto)
      expired_at =
        DateTime.utc_now()
        |> DateTime.add(-1, :day)
        |> DateTime.truncate(:second)

      invitation
      |> Ecto.Changeset.change(%{expires_at: expired_at})
      |> Aces.Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/invitations")

      assert html =~ "Received History"
      assert html =~ "Expired Company"
      assert html =~ "Expired"
    end

    test "requires authentication", %{conn: conn} do
      conn = conn |> log_out_user()

      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/invitations")

      assert path == ~p"/users/log-in"
    end
  end

  defp log_out_user(conn) do
    Plug.Conn.delete_session(conn, :user_token)
  end
end
