defmodule AcesWeb.InvitationLive.IndexTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures

  setup :register_and_log_in_user

  describe "Invitations Sent - Resend" do
    test "sender can resend pending invitation", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      # Create a pending invitation
      {:ok, {original_token, invitation}} =
        Aces.Companies.create_invitation(company, user, "invitee@example.com", "editor")

      {:ok, view, html} = live(conn, ~p"/invitations")

      # Should see sent invitation with resend button
      assert html =~ "Invitations Sent"
      assert html =~ "invitee@example.com"
      assert html =~ "Resend"

      # Click resend button
      view |> element("button", "Resend") |> render_click()

      # Verify the original token is now invalid
      assert {:error, :invalid_token} = Aces.Companies.get_invitation_by_token(original_token)

      # Verify invitation is still pending with extended expiry
      updated_invitation = Aces.Companies.get_invitation!(invitation.id)
      assert updated_invitation.status == "pending"
      assert DateTime.diff(updated_invitation.expires_at, DateTime.utc_now(), :day) >= 6
    end

    test "can resend expired pending invitation", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      # Create invitation and manually expire it
      {:ok, {original_token, invitation}} =
        Aces.Companies.create_invitation(company, user, "invitee@example.com", "editor")

      # Manually expire the invitation
      expired_at = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      invitation
      |> Ecto.Changeset.change(%{expires_at: expired_at})
      |> Aces.Repo.update!()

      # Verify original token is invalid
      assert {:error, :invalid_token} = Aces.Companies.get_invitation_by_token(original_token)

      {:ok, view, html} = live(conn, ~p"/invitations")

      # Should see sent invitation with resend button (even for expired)
      assert html =~ "invitee@example.com"
      assert html =~ "Resend"
      assert html =~ "Expired"

      # Click resend button
      view |> element("button", "Resend") |> render_click()

      # Verify invitation is now valid again with extended expiry
      updated_invitation = Aces.Companies.get_invitation!(invitation.id)
      assert updated_invitation.status == "pending"
      assert DateTime.diff(updated_invitation.expires_at, DateTime.utc_now(), :day) >= 6
    end

    test "cannot resend accepted invitation", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      invitee = user_fixture(email: "invitee@example.com")

      # Create and accept invitation
      {:ok, {_token, invitation}} =
        Aces.Companies.create_invitation(company, user, "invitee@example.com", "editor")

      invitation = Aces.Companies.get_invitation!(invitation.id)
      {:ok, _} = Aces.Companies.accept_invitation(invitation, invitee)

      {:ok, _view, html} = live(conn, ~p"/invitations")

      # Should see sent invitation but not resend button (it's accepted)
      assert html =~ "invitee@example.com"
      assert html =~ "Accepted"
      # Resend button should not appear for accepted invitations
      refute html =~ ~r/Resend.*invitee@example.com/s
    end
  end
end
