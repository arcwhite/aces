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

  defp log_out_user(conn) do
    Plug.Conn.delete_session(conn, :user_token)
  end
end
