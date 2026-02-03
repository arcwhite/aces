defmodule AcesWeb.CompanyLive.ShowTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures

  setup :register_and_log_in_user

  describe "Show page" do
    test "displays active company information", %{conn: conn, user: user} do
      company = company_fixture(user: user, name: "Test Company", description: "Test description", status: "active")

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      assert html =~ "Test Company"
      assert html =~ "Test description"
    end

    test "has tabbed navigation with Overview, Pilots, Units, Settings tabs", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      {:ok, show_live, html} = live(conn, ~p"/companies/#{company.id}")

      # All tabs should be visible
      assert html =~ "Overview"
      assert html =~ "Pilots"
      assert html =~ "Units"
      assert html =~ "Settings"

      # Overview tab should be active by default and show stats
      assert html =~ "Active Campaign"
      assert html =~ "Warchest"

      # Click on Pilots tab
      html = show_live |> element("button", "Pilots") |> render_click()
      assert html =~ "Pilot Roster"

      # Click on Units tab
      html = show_live |> element("button", "Units") |> render_click()
      assert html =~ "Unit Roster"

      # Click on Settings tab
      html = show_live |> element("button", "Settings") |> render_click()
      assert html =~ "Team Members"
      assert html =~ "Danger Zone"

      # Wait for any PubSub-triggered reloads to complete
      render(show_live)
    end

    test "redirects draft companies to draft setup page", %{conn: conn, user: user} do
      company = company_fixture(user: user, name: "Draft Company", status: "draft")

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/companies/#{company.id}")
      assert path == ~p"/companies/#{company}/draft"
    end

    test "displays company stats", %{conn: conn, user: user} do
      company = company_fixture(user: user, warchest_balance: 7500, status: "active")
      company_unit_fixture(company: company)
      company_unit_fixture(company: company)
      company_unit_fixture(company: company)

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      # unit count
      assert html =~ "3"
      # warchest
      assert html =~ "7500"
    end

    test "shows empty roster message when no units", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      {:ok, show_live, _html} = live(conn, ~p"/companies/#{company.id}")

      # Navigate to Units tab to see the unit roster
      html = show_live |> element("button", "Units") |> render_click()

      assert html =~ "No units yet"
      assert html =~ "Start a campaign to purchase units"

      # Wait for any PubSub-triggered reloads to complete
      render(show_live)
    end

    test "displays unit roster when units exist", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      master_unit = master_unit_fixture(name: "Atlas", variant: "AS7-D")
      company_unit_fixture(company: company, master_unit: master_unit, custom_name: "The Hammer")

      {:ok, show_live, _html} = live(conn, ~p"/companies/#{company.id}")

      # Navigate to Units tab to see the unit roster
      html = show_live |> element("button", "Units") |> render_click()

      assert html =~ "Atlas AS7-D"
      assert html =~ "The Hammer"

      # Wait for any PubSub-triggered reloads to complete
      render(show_live)
    end

    test "has back to companies link", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      assert html =~ "Back to Companies"
      assert html =~ ~p"/companies"
    end

    test "draft companies redirect to draft page", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft")

      # This should redirect to draft page, not show the company page  
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/companies/#{company.id}")
      assert path == ~p"/companies/#{company}/draft"
    end

    test "shows campaign purchase guidance for active companies", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      # Overview tab should show the campaign purchase guidance
      assert html =~ "Unit Purchases"
      assert html =~ "Pilot Hiring"
      assert html =~ "Start a campaign to purchase units"
    end

    test "prevents access when user is not a member", %{conn: conn} do
      other_user = user_fixture()
      company = company_fixture(user: other_user, status: "active")

      assert {:error, {:redirect, %{flash: %{"error" => _}, to: "/companies"}}} =
               live(conn, ~p"/companies/#{company.id}")
    end

    test "allows viewer to view but not edit", %{conn: conn, user: user} do
      %{company: company, viewer: _viewer} = company_with_members_fixture(status: "active")
      Aces.Companies.add_member(company, user, "viewer")

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      # Can view
      assert html =~ company.name

      # Overview tab shows the guidance message about campaign purchases
      assert html =~ "Unit Purchases"
      assert html =~ "Pilot Hiring"
    end

    test "prevents unauthorized access when not logged in", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      conn = conn |> log_out_user()

      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/companies/#{company.id}")

      assert path == ~p"/users/log-in"
    end
  end

  describe "Invite Member Modal" do
    test "owner can open invite modal from Settings tab", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.id}")

      # Navigate to Settings tab
      html = view |> element("button", "Settings") |> render_click()
      assert html =~ "Invite Member"

      # Click invite button
      html = view |> element("button", "Invite Member") |> render_click()
      assert html =~ "Email Address"
      assert html =~ "Send Invitation"
    end

    test "modal persists across tab changes (bug fix validation)", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.id}")

      # Navigate to Settings tab and open modal
      view |> element("button", "Settings") |> render_click()
      view |> element("button", "Invite Member") |> render_click()

      # Verify modal is open
      html = render(view)
      assert html =~ "Send Invitation"

      # Switch to Overview tab - modal should stay open
      html = view |> element("button", "Overview") |> render_click()
      assert html =~ "Send Invitation"

      # Switch to Units tab - modal should still be open
      html = view |> element("button", "Units") |> render_click()
      assert html =~ "Send Invitation"

      # Switch back to Settings tab - modal should still be open
      html = view |> element("button", "Settings") |> render_click()
      assert html =~ "Send Invitation"
    end

    test "can send invitation through modal", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.id}")

      # Navigate to Settings tab and open modal
      view |> element("button", "Settings") |> render_click()
      view |> element("button", "Invite Member") |> render_click()

      # Fill out and submit form
      view
      |> form("form", %{"email" => "newmember@example.com", "role" => "editor"})
      |> render_submit()

      # Render the view to get updated state after form submission
      html = render(view)

      # Modal should be closed (no modal-open class)
      refute html =~ "modal-open"

      # Verify invitation appears in pending list
      assert html =~ "newmember@example.com"
      assert html =~ "Pending Invitations"

      # Verify the invitation was actually created in the database
      invitations = Aces.Companies.list_pending_invitations(company)
      assert length(invitations) == 1
      assert hd(invitations).invited_email == "newmember@example.com"
      assert hd(invitations).role == "editor"
    end

    test "viewer cannot see invite button", %{conn: conn, user: user} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")
      {:ok, _} = Aces.Companies.add_member(company, user, "viewer")

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.id}")

      # Navigate to Settings tab
      html = view |> element("button", "Settings") |> render_click()

      # Viewer should see team members but not invite button (button element)
      assert html =~ "Team Members"
      refute html =~ ~r/<button[^>]*>.*Invite Member.*<\/button>/s
    end

    test "editor cannot see invite button", %{conn: conn, user: user} do
      owner = user_fixture()
      company = company_fixture(user: owner, status: "active")
      {:ok, _} = Aces.Companies.add_member(company, user, "editor")

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.id}")

      # Navigate to Settings tab
      html = view |> element("button", "Settings") |> render_click()

      # Editor should see team members but not invite button (button element)
      assert html =~ "Team Members"
      refute html =~ ~r/<button[^>]*>.*Invite Member.*<\/button>/s
    end

    test "modal can be closed", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.id}")

      # Navigate to Settings tab and open modal
      view |> element("button", "Settings") |> render_click()
      view |> element("button", "Invite Member") |> render_click()

      # Verify modal is open
      html = render(view)
      assert html =~ "Send Invitation"

      # Close the modal using the Cancel button (inside the component)
      view |> element("button.btn-ghost", "Cancel") |> render_click()

      # Render the view to get the updated state
      html = render(view)

      # Modal content should no longer be visible (modal hides via :if={@show})
      refute html =~ "modal-open"
    end
  end

  defp log_out_user(conn) do
    Plug.Conn.delete_session(conn, :user_token)
  end

  describe "URL-based modal state persistence" do
    test "invite modal opens via URL param", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      # Open modal directly via URL
      {:ok, _view, html} = live(conn, ~p"/companies/#{company}?modal=invite")
      assert html =~ "Send Invitation"
    end

    test "invite modal state survives simulated reconnection", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      # Open modal via URL
      {:ok, _view, html} = live(conn, ~p"/companies/#{company}?modal=invite")
      assert html =~ "Send Invitation"

      # Simulate reconnection by re-mounting with same URL (new LiveView session)
      {:ok, _view2, html2} = live(conn, ~p"/companies/#{company}?modal=invite")
      assert html2 =~ "Send Invitation"
    end

    test "unit edit modal opens via URL param with unit_id", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      master_unit = master_unit_fixture(name: "Atlas", variant: "AS7-D")
      unit = company_unit_fixture(company: company, master_unit: master_unit)

      # Open unit edit modal via URL
      {:ok, _view, html} = live(conn, ~p"/companies/#{company}?modal=unit_edit&unit_id=#{unit.id}")
      assert html =~ "Edit Unit"
    end

    test "unit edit modal state survives simulated reconnection", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      master_unit = master_unit_fixture(name: "Atlas", variant: "AS7-D")
      unit = company_unit_fixture(company: company, master_unit: master_unit)

      # Open modal via URL
      {:ok, _view, html} = live(conn, ~p"/companies/#{company}?modal=unit_edit&unit_id=#{unit.id}")
      assert html =~ "Edit Unit"

      # Simulate reconnection
      {:ok, _view2, html2} = live(conn, ~p"/companies/#{company}?modal=unit_edit&unit_id=#{unit.id}")
      assert html2 =~ "Edit Unit"
    end

    test "pilot edit modal opens via URL param with pilot_id", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      pilot = pilot_fixture(company: company, name: "Test Pilot")

      # Open pilot edit modal via URL
      {:ok, _view, html} = live(conn, ~p"/companies/#{company}?modal=pilot_edit&pilot_id=#{pilot.id}")
      assert html =~ "Edit Pilot"
    end

    test "pilot edit modal state survives simulated reconnection", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      pilot = pilot_fixture(company: company, name: "Test Pilot")

      # Open modal via URL
      {:ok, _view, html} = live(conn, ~p"/companies/#{company}?modal=pilot_edit&pilot_id=#{pilot.id}")
      assert html =~ "Edit Pilot"

      # Simulate reconnection
      {:ok, _view2, html2} = live(conn, ~p"/companies/#{company}?modal=pilot_edit&pilot_id=#{pilot.id}")
      assert html2 =~ "Edit Pilot"
    end

    test "clicking invite button updates URL with modal param", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      {:ok, view, _html} = live(conn, ~p"/companies/#{company}")

      # Navigate to Settings tab and click invite
      view |> element("button", "Settings") |> render_click()
      view |> element("button", "Invite Member") |> render_click()

      # Verify the URL was updated (modal should be open)
      assert render(view) =~ "Send Invitation"
    end

    test "closing invite modal clears URL param", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      {:ok, view, _html} = live(conn, ~p"/companies/#{company}?modal=invite")
      assert render(view) =~ "Send Invitation"

      # Close the modal
      view |> element("button.btn-ghost", "Cancel") |> render_click()

      # Modal should be closed
      html = render(view)
      refute html =~ "modal-open"
    end

    test "clicking edit unit button updates URL", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      master_unit = master_unit_fixture(name: "Atlas", variant: "AS7-D")
      _unit = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, view, _html} = live(conn, ~p"/companies/#{company}")

      # Navigate to Units tab
      view |> element("button", "Units") |> render_click()

      # Click edit button
      view |> element("button", "Edit") |> render_click()

      # Modal should be open
      assert render(view) =~ "Edit Unit"
    end

    test "invalid unit_id in URL does not open modal", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      # Modal should not open for non-existent unit
      {:ok, view, _html} = live(conn, ~p"/companies/#{company}?modal=unit_edit&unit_id=99999")
      html = render(view)

      # Modal should not be open (no Edit Unit title visible)
      refute html =~ "modal-open"
      # Page should still load the company
      assert html =~ company.name
    end

    test "invalid pilot_id in URL does not open modal", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      # Modal should not open for non-existent pilot
      {:ok, view, _html} = live(conn, ~p"/companies/#{company}?modal=pilot_edit&pilot_id=99999")
      html = render(view)

      # Modal should not be open
      refute html =~ "modal-open"
      # Page should still load the company
      assert html =~ company.name
    end

    test "malformed unit_id in URL is handled gracefully", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      # Should not crash with non-integer ID
      {:ok, view, _html} = live(conn, ~p"/companies/#{company}?modal=unit_edit&unit_id=abc")
      html = render(view)

      # Modal should not be open
      refute html =~ "modal-open"
      # Page should still load the company
      assert html =~ company.name
    end

    test "malformed pilot_id in URL is handled gracefully", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      # Should not crash with non-integer ID
      {:ok, view, _html} = live(conn, ~p"/companies/#{company}?modal=pilot_edit&pilot_id=abc")
      html = render(view)

      # Modal should not be open
      refute html =~ "modal-open"
      # Page should still load the company
      assert html =~ company.name
    end
  end

  describe "Resend Invitation" do
    test "owner can resend pending invitation from Settings tab", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      # Create a pending invitation and get the original token
      {:ok, {original_token, invitation}} =
        Aces.Companies.create_invitation(company, user, "invitee@example.com", "editor")

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.id}")

      # Navigate to Settings tab
      html = view |> element("button", "Settings") |> render_click()

      # Should see pending invitation with resend button
      assert html =~ "Pending Invitations"
      assert html =~ "invitee@example.com"
      assert html =~ "Resend"

      # Click resend button
      view |> element("button", "Resend") |> render_click()

      # Verify the original token is now invalid (token was refreshed)
      assert {:error, :invalid_token} = Aces.Companies.get_invitation_by_token(original_token)

      # Verify invitation is still pending with extended expiry
      updated_invitation = Aces.Companies.get_invitation!(invitation.id)
      assert updated_invitation.status == "pending"
      assert DateTime.diff(updated_invitation.expires_at, DateTime.utc_now(), :day) >= 6
    end

    test "resend invitation generates new token", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      # Create invitation and get the original token
      {:ok, {original_token, invitation}} =
        Aces.Companies.create_invitation(company, user, "invitee@example.com", "editor")

      # Verify original token is valid
      assert {:ok, _} = Aces.Companies.get_invitation_by_token(original_token)

      {:ok, view, _html} = live(conn, ~p"/companies/#{company.id}")

      # Navigate to Settings tab and click resend
      view |> element("button", "Settings") |> render_click()
      view |> element("button", "Resend") |> render_click()

      # Original token should now be invalid
      assert {:error, :invalid_token} = Aces.Companies.get_invitation_by_token(original_token)

      # Invitation should still be pending
      updated_invitation = Aces.Companies.get_invitation!(invitation.id)
      assert updated_invitation.status == "pending"
    end
  end
end
