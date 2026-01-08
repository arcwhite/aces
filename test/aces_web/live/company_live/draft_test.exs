defmodule AcesWeb.CompanyLive.DraftTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures

  describe "Draft company setup" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "displays draft company setup page", %{conn: conn, user: user} do
      company = company_fixture(user: user, name: "Test Company", status: "draft")

      {:ok, _draft_live, html} = live(conn, ~p"/companies/#{company}/draft")

      assert html =~ "Company Setup: Test Company"
      assert html =~ "DRAFT"
      assert html =~ "400 PV</strong> to build your company roster"
      assert html =~ "1 PV = 40 SP"
    end

    test "shows PV budget and usage correctly", %{conn: conn, user: user} do
      company = company_fixture(
        user: user,
        name: "Budget Test",
        status: "draft",
        pv_budget: 400,
        warchest_balance: 1000
      )

      # Add a unit that costs 100 PV
      master_unit = master_unit_fixture(point_value: 100)
      company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, _draft_live, html} = live(conn, ~p"/companies/#{company}/draft")

      assert html =~ "300/400"  # PV remaining/budget
      assert html =~ "100 PV used"
      assert html =~ "13000"  # Future warchest: 1000 + (300 * 40)
    end

    test "allows finalizing company", %{conn: conn, user: user} do
      company = company_fixture(
        user: user,
        status: "draft",
        pv_budget: 400,
        warchest_balance: 1000
      )

      {:ok, draft_live, _html} = live(conn, ~p"/companies/#{company}/draft")

      # Click finalize company button
      draft_live
      |> element("button[phx-click='finalize_company']")
      |> render_click()

      # Should redirect to company show page
      assert_redirected(draft_live, ~p"/companies/#{company}")

      # Verify company was finalized
      updated_company = Aces.Companies.get_company!(company.id)
      assert updated_company.status == "active"
      assert updated_company.warchest_balance == 17_000  # 1000 + (400 * 40)
    end

    test "shows finalization summary correctly", %{conn: conn, user: user} do
      company = company_fixture(
        user: user,
        status: "draft",
        pv_budget: 200,
        warchest_balance: 500
      )

      # Add a unit that uses 75 PV, leaving 125 unused
      master_unit = master_unit_fixture(point_value: 75)
      company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, _draft_live, html} = live(conn, ~p"/companies/#{company}/draft")

      assert html =~ "Units in roster: 1"
      assert html =~ "PV used: 75/200"
      assert html =~ "Starting warchest: 500 SP"
      assert html =~ "Bonus SP from unused PV: 5000 SP"  # 125 * 40
      assert html =~ "Total starting warchest: 5500 SP"  # 500 + 5000
    end

    test "redirects non-draft companies to show page", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/companies/#{company}/draft")
      assert path == ~p"/companies/#{company}"
    end

    test "shows unauthorized for companies user can't edit", %{conn: conn} do
      other_user = user_fixture()
      company = company_fixture(user: other_user, status: "draft")

      assert {:error, {:redirect, %{to: "/companies"}}} = live(conn, ~p"/companies/#{company}/draft")
    end

    test "displays unit search modal when add unit clicked", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft")

      {:ok, draft_live, _html} = live(conn, ~p"/companies/#{company}/draft")

      # Click add unit button
      draft_live
      |> element("button[phx-click='add_unit']")
      |> render_click()

      # Check modal is displayed
      html = render(draft_live)
      assert html =~ "Add Unit to Roster"
      assert html =~ "Search for units"
      assert html =~ "Master Unit List"
    end

    test "closes unit search modal when close clicked", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft")

      {:ok, draft_live, _html} = live(conn, ~p"/companies/#{company}/draft")

      # Open modal
      draft_live
      |> element("button[phx-click='add_unit']")
      |> render_click()

      # Close modal
      draft_live
      |> element("button[phx-click='close_unit_search']")
      |> render_click()

      # Check modal is closed
      html = render(draft_live)
      refute html =~ "modal modal-open"
    end

    test "displays company with no units message", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft")

      {:ok, _draft_live, html} = live(conn, ~p"/companies/#{company}/draft")

      assert html =~ "No units selected yet"
      assert html =~ "Add your first unit to get started!"
    end

    test "displays company units in roster table", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft")
      master_unit = master_unit_fixture(name: "Atlas", variant: "AS7-D", point_value: 48)
      company_unit_fixture(
        company: company, 
        master_unit: master_unit,
        purchase_cost_sp: 1920
      )

      {:ok, _draft_live, html} = live(conn, ~p"/companies/#{company}/draft")

      assert html =~ "Atlas AS7-D"
      assert html =~ "1920 SP"
      assert html =~ "48"  # PV
      refute html =~ "No units selected yet"
    end

    test "allows adding units with PV in draft mode", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft", pv_budget: 400)

      {:ok, draft_live, html} = live(conn, ~p"/companies/#{company}/draft")

      # Should show Add Unit button
      assert html =~ "Add Unit"
      
      # Click Add Unit should open modal
      draft_live
      |> element("button[phx-click='add_unit']")
      |> render_click()

      html = render(draft_live)
      assert html =~ "Add Unit to Roster"
    end

    test "allows removing units and restores PV points", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft", pv_budget: 400)
      master_unit = master_unit_fixture(name: "Locust", variant: "LCT-1V", point_value: 25)
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      {:ok, draft_live, html} = live(conn, ~p"/companies/#{company}/draft")

      # Should show the unit in the roster
      assert html =~ "Locust LCT-1V"
      assert html =~ "375/400"  # 400 - 25 PV used
      assert html =~ "25 PV used"

      # Click remove button
      draft_live
      |> element("button[phx-click='remove_unit'][phx-value-unit_id='#{company_unit.id}']")
      |> render_click()

      # Should show confirmation and unit should be removed
      html = render(draft_live)
      assert html =~ "Unit removed from roster!"
      refute html =~ "Locust LCT-1V"
      assert html =~ "400/400"  # Full PV restored
      assert html =~ "0 PV used"
      assert html =~ "No units selected yet"
    end

    test "shows error when trying to remove non-existent unit", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft")

      {:ok, draft_live, _html} = live(conn, ~p"/companies/#{company}/draft")

      # Try to remove unit that doesn't exist
      render_click(draft_live, "remove_unit", %{"unit_id" => "99999"})

      html = render(draft_live)
      assert html =~ "Unit not found"
    end

    test "prevents unauthorized users from removing units", %{conn: conn} do
      other_user = user_fixture()
      company = company_fixture(user: other_user, status: "draft")

      # Try to access as unauthorized user
      assert {:error, {:redirect, %{to: "/companies"}}} = live(conn, ~p"/companies/#{company}/draft")
    end

    test "displays pilot form modal when add pilot clicked", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft")

      {:ok, draft_live, _html} = live(conn, ~p"/companies/#{company}/draft")

      # Click add pilot button
      draft_live
      |> element("button[phx-click='add_pilot']")
      |> render_click()

      # Check modal is displayed
      html = render(draft_live)
      assert html =~ "Add Pilot to Company"
      assert html =~ "Add New Pilot"
    end

    test "displays no pilots message when no pilots exist", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft")

      {:ok, _draft_live, html} = live(conn, ~p"/companies/#{company}/draft")

      assert html =~ "No pilots recruited yet"
      assert html =~ "Add skilled pilots to operate your units!"
    end

    test "displays pilots in roster cards", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft")
      _pilot = pilot_fixture(company: company, name: "Jane Doe", callsign: "Phoenix")

      {:ok, _draft_live, html} = live(conn, ~p"/companies/#{company}/draft")

      # Check that pilot is loaded and displayed correctly
      assert html =~ "Jane Doe"
      assert html =~ "Phoenix"  
      assert html =~ "1/6"  # Pilot count should be 1 out of 6
      refute html =~ "No pilots recruited yet"
      
      # Check that pilot details are shown (skill, edge, status)
      assert html =~ "Skill"
      assert html =~ "Edge"
      assert html =~ "4"  # Skill level
      assert html =~ "2"  # Edge tokens
    end

    test "allows removing pilots from company", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft")
      pilot = pilot_fixture(company: company, name: "Test Pilot", callsign: "Eagle")

      {:ok, draft_live, html} = live(conn, ~p"/companies/#{company}/draft")

      # Should show the pilot in the roster
      assert html =~ "Test Pilot"
      assert html =~ "Eagle"
      assert html =~ "1/6"  # Pilot count

      # Click remove button
      draft_live
      |> element("button[phx-click='remove_pilot'][phx-value-pilot_id='#{pilot.id}']")
      |> render_click()

      # Should show confirmation and pilot should be removed
      html = render(draft_live)
      assert html =~ "Pilot removed from company!"
      refute html =~ "\"Eagle\" Test Pilot"
      assert html =~ "0/6"  # Pilot count reduced
      assert html =~ "No pilots recruited yet"
    end

    test "shows error when trying to remove non-existent pilot", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "draft")

      {:ok, draft_live, _html} = live(conn, ~p"/companies/#{company}/draft")

      # Send remove_pilot event directly with non-existent pilot ID to test server-side validation
      html = render_hook(draft_live, "remove_pilot", %{"pilot_id" => "99999"})
      
      assert html =~ "Pilot not found"
    end
  end
end