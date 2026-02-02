defmodule AcesWeb.SortieLive.NewTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures
  import Aces.UnitsFixtures

  setup :register_and_log_in_user

  describe "New sortie page" do
    setup %{user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      pilot = pilot_fixture(company: company)
      master_unit = units_master_unit_fixture()
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)

      %{company: company, campaign: campaign, pilot: pilot, company_unit: company_unit}
    end

    test "renders new sortie form", %{conn: conn, company: company, campaign: campaign} do
      {:ok, _new_live, html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      assert html =~ "Create New Sortie"
      assert html =~ "Mission Details"
      assert html =~ "Unit Deployment"
      assert html =~ "Reconnaissance Options"
      assert html =~ "Mission Number"
      assert html =~ "Mission Name"
      assert html =~ "Point Value Limit"
    end

    test "shows company units available for deployment", %{conn: conn, company: company, campaign: campaign, company_unit: company_unit} do
      {:ok, _new_live, html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Check for either custom name or master unit name
      unit_name = company_unit.custom_name || company_unit.master_unit.name
      assert html =~ unit_name
      assert html =~ "#{company_unit.master_unit.point_value} PV"
    end

    test "shows pilots available for assignment", %{conn: conn, company: company, campaign: campaign, pilot: pilot, company_unit: company_unit} do
      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Need to deploy a unit first to see pilot selection
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{company_unit.id}']")
      |> render_click()

      html = render(new_live)
      assert html =~ pilot.callsign
      assert html =~ "Skill #{pilot.skill_level}"
    end

    test "toggles unit deployment when clicked", %{conn: conn, company: company, campaign: campaign, company_unit: company_unit} do
      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Initially no units deployed
      html = render(new_live)
      assert html =~ "Units Deployed"
      assert html =~ ">0<"

      # Click to deploy unit
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{company_unit.id}']")
      |> render_click()

      html = render(new_live)
      assert html =~ "Units Deployed"
      assert html =~ ">1<"
      # Check for either custom name or master unit name
      unit_name = company_unit.custom_name || company_unit.master_unit.name
      assert html =~ unit_name

      # Click again to undeploy unit
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{company_unit.id}']")
      |> render_click()

      html = render(new_live)
      assert html =~ "Units Deployed"
      assert html =~ ">0<"
    end

    test "assigns pilot to deployed unit", %{conn: conn, company: company, campaign: campaign, company_unit: company_unit, pilot: pilot} do
      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Deploy unit first
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{company_unit.id}']")
      |> render_click()

      # Assign pilot using phx-blur event
      new_live
      |> element("select[phx-value-unit_id='#{company_unit.id}']")
      |> render_blur(%{"value" => "#{pilot.id}"})

      html = render(new_live)
      assert html =~ pilot.callsign
    end

    test "creates sortie with valid data and deployments", %{conn: conn, user: _user, company: company, campaign: campaign, company_unit: company_unit, pilot: pilot} do
      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Deploy unit
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{company_unit.id}']")
      |> render_click()

      # Assign pilot using phx-blur event  
      new_live
      |> element("select[phx-value-unit_id='#{company_unit.id}']")
      |> render_blur(%{"value" => "#{pilot.id}"})

      # Verify pilot was assigned
      html = render(new_live)
      assert html =~ pilot.callsign

      form_data = %{
        "sortie" => %{
          "mission_number" => "1",
          "name" => "Test Mission",
          "description" => "A test mission",
          "pv_limit" => "200"
        }
      }

      result =
        new_live
        |> form("#sortie-form", form_data)
        |> render_submit()

      # Should redirect to sortie show page (setup view)
      assert {:error, {:redirect, %{to: path}}} = result

      # Verify the sortie was created
      campaign = Aces.Campaigns.get_campaign!(campaign.id)
      assert length(campaign.sorties) == 1
      sortie = List.first(campaign.sorties)
      assert path == ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}"

      assert sortie.mission_number == "1"
      assert sortie.name == "Test Mission"
      assert sortie.description == "A test mission"
      assert sortie.pv_limit == 200
      assert sortie.status == "setup"

      # Verify deployment was created
      assert length(sortie.deployments) == 1
      deployment = List.first(sortie.deployments)
      assert deployment.company_unit_id == company_unit.id
      assert deployment.pilot_id == pilot.id
    end

    test "shows validation errors with invalid data", %{conn: conn, company: company, campaign: campaign, company_unit: company_unit} do
      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Deploy unit to avoid deployment validation
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{company_unit.id}']")
      |> render_click()

      form_data = %{
        "sortie" => %{
          "mission_number" => "",
          "name" => "",
          "pv_limit" => "-100"
        }
      }

      html =
        new_live
        |> form("#sortie-form", form_data)
        |> render_change()

      assert html =~ "can&#39;t be blank"
      assert html =~ "must be greater than 0"
    end

    test "validates mission number format", %{conn: conn, company: company, campaign: campaign, company_unit: company_unit} do
      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Deploy unit
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{company_unit.id}']")
      |> render_click()

      form_data = %{
        "sortie" => %{
          "mission_number" => "invalid-format",
          "name" => "Test Mission",
          "pv_limit" => "200"
        }
      }

      html =
        new_live
        |> form("#sortie-form", form_data)
        |> render_change()

      assert html =~ "must be a number, optionally followed by a letter"
    end

    test "prevents submission without unit deployments", %{conn: conn, company: company, campaign: campaign} do
      {:ok, _new_live, html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Should show warning when no units are deployed
      assert html =~ "Select at least one unit to deploy"
      
      # Submit button should be disabled when no units deployed
      assert html =~ "disabled" and html =~ "Create Sortie"
    end

    test "prevents unauthorized access when user can't edit company", %{conn: conn} do
      other_user = user_fixture()
      company = company_fixture(user: other_user)
      campaign = campaign_fixture(company)

      assert {:error, {:redirect, %{to: path}}} = 
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      assert path == ~p"/companies"
    end

    test "has back to campaign link", %{conn: conn, company: company, campaign: campaign} do
      {:ok, _new_live, html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      assert html =~ "Back to Campaign"
      assert html =~ ~p"/companies/#{company.id}/campaigns/#{campaign.id}"
    end

    test "only shows pilots qualified for the unit type", %{conn: conn, user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)

      # Create pilots for different unit types
      mech_pilot = pilot_fixture(company: company, callsign: "MechPilot", unit_type: "battlemech")
      tank_pilot = pilot_fixture(company: company, callsign: "TankPilot", unit_type: "combat_vehicle")
      ba_pilot = pilot_fixture(company: company, callsign: "BAPilot", unit_type: "battle_armor")

      # Create units of different types
      mech_master = master_unit_fixture(unit_type: "battlemech", name: "Atlas", variant: "AS7-D")
      tank_master = master_unit_fixture(unit_type: "combat_vehicle", name: "Demolisher", variant: "II")

      mech_unit = company_unit_fixture(company: company, master_unit: mech_master, custom_name: "TestMech")
      tank_unit = company_unit_fixture(company: company, master_unit: tank_master, custom_name: "TestTank")

      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Deploy the BattleMech unit
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{mech_unit.id}']")
      |> render_click()

      html = render(new_live)
      # Only battlemech pilot should be visible for the mech
      assert html =~ mech_pilot.callsign
      refute html =~ tank_pilot.callsign
      refute html =~ ba_pilot.callsign

      # Deploy the tank unit as well
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{tank_unit.id}']")
      |> render_click()

      html = render(new_live)
      # Now tank pilot should be visible (for the tank unit)
      assert html =~ tank_pilot.callsign
    end

    test "shows warning when no pilots are qualified for unit type", %{conn: conn, user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)

      # Create only a tank pilot
      _tank_pilot = pilot_fixture(company: company, callsign: "TankPilot", unit_type: "combat_vehicle")

      # Create a battlemech unit
      mech_master = master_unit_fixture(unit_type: "battlemech", name: "Atlas", variant: "AS7-D")
      mech_unit = company_unit_fixture(company: company, master_unit: mech_master, custom_name: "TestMech")

      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Deploy the BattleMech unit
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{mech_unit.id}']")
      |> render_click()

      html = render(new_live)
      assert html =~ "No pilots qualified for BattleMech"
    end

    test "does not show pilot dropdown for conventional infantry", %{conn: conn, user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)

      # Create a pilot
      _pilot = pilot_fixture(company: company)

      # Create a conventional infantry unit
      infantry_master = master_unit_fixture(unit_type: "conventional_infantry", name: "Foot Platoon", variant: "Standard")
      infantry_unit = company_unit_fixture(company: company, master_unit: infantry_master, custom_name: "TestInfantry")

      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Deploy the infantry unit
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{infantry_unit.id}']")
      |> render_click()

      html = render(new_live)
      # Should show message that infantry cannot have pilots
      assert html =~ "Infantry units cannot have assigned pilots"
      # Should not show pilot select for infantry
      refute html =~ "select[phx-value-unit_id='#{infantry_unit.id}']"
    end

    test "disables checkbox for units that would exceed PV limit", %{conn: conn, user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)

      # Create a small unit (20 PV) and a large unit (50 PV)
      small_master = master_unit_fixture(name: "Small Mech", variant: "SM-1", point_value: 20)
      large_master = master_unit_fixture(name: "Large Mech", variant: "LG-1", point_value: 50)

      small_unit = company_unit_fixture(company: company, master_unit: small_master, custom_name: "SmallUnit")
      large_unit = company_unit_fixture(company: company, master_unit: large_master, custom_name: "LargeUnit")

      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Set a low PV limit of 40
      new_live
      |> form("#sortie-form", %{"sortie" => %{"pv_limit" => "40", "mission_number" => "1", "name" => "Test"}})
      |> render_change()

      html = render(new_live)

      # Large unit checkbox should be disabled (50 PV > 40 limit)
      assert html =~ "disabled" <> ~s( phx-click="toggle_unit_deployment" phx-value-unit_id="#{large_unit.id}") or
             html =~ ~s(phx-value-unit_id="#{large_unit.id}") && html =~ "Exceeds PV"

      # Small unit should be enabled (20 PV <= 40 limit)
      small_checkbox_html = Regex.run(~r/<input[^>]*phx-value-unit_id="#{small_unit.id}"[^>]*>/, html)
      assert small_checkbox_html != nil
      refute Enum.any?(small_checkbox_html, &String.contains?(&1, "disabled"))
    end

    test "shows 'Exceeds PV' badge on units that would exceed limit", %{conn: conn, user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)

      # Create a unit that's larger than our PV limit
      large_master = master_unit_fixture(name: "Huge Mech", variant: "HG-1", point_value: 100)
      _large_unit = company_unit_fixture(company: company, master_unit: large_master, custom_name: "HugeUnit")

      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Set PV limit lower than the unit's PV
      new_live
      |> form("#sortie-form", %{"sortie" => %{"pv_limit" => "50", "mission_number" => "1", "name" => "Test"}})
      |> render_change()

      html = render(new_live)

      # Should show "Exceeds PV" badge for the large unit
      assert html =~ "Exceeds PV"

      # The card should have muted text styling (bg-base-200 background)
      assert html =~ "bg-base-200"
    end

    test "dynamically disables units as more units are deployed", %{conn: conn, user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)

      # Create three units of 30 PV each
      master1 = master_unit_fixture(name: "Unit A", variant: "A-1", point_value: 30)
      master2 = master_unit_fixture(name: "Unit B", variant: "B-1", point_value: 30)
      master3 = master_unit_fixture(name: "Unit C", variant: "C-1", point_value: 30)

      unit1 = company_unit_fixture(company: company, master_unit: master1, custom_name: "UnitA")
      unit2 = company_unit_fixture(company: company, master_unit: master2, custom_name: "UnitB")
      _unit3 = company_unit_fixture(company: company, master_unit: master3, custom_name: "UnitC")

      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Set PV limit to 60 (can fit 2 units of 30 PV each)
      new_live
      |> form("#sortie-form", %{"sortie" => %{"pv_limit" => "60", "mission_number" => "1", "name" => "Test"}})
      |> render_change()

      # Initially all units should be selectable (none deployed, each fits within 60)
      html = render(new_live)
      refute html =~ "Exceeds PV"

      # Deploy first unit (30 PV used, 30 remaining)
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{unit1.id}']")
      |> render_click()

      # Still no units should exceed (30 PV remaining, each unit is 30)
      html = render(new_live)
      refute html =~ "Exceeds PV"

      # Deploy second unit (60 PV used, 0 remaining)
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{unit2.id}']")
      |> render_click()

      # Now third unit should show "Exceeds PV" (0 PV remaining)
      html = render(new_live)
      assert html =~ "Exceeds PV"
    end

    test "re-enables units when PV limit is increased", %{conn: conn, user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)

      # Create a unit
      master = master_unit_fixture(name: "Medium Mech", variant: "MM-1", point_value: 40)
      _unit = company_unit_fixture(company: company, master_unit: master, custom_name: "MediumUnit")

      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Set low PV limit first
      new_live
      |> form("#sortie-form", %{"sortie" => %{"pv_limit" => "30", "mission_number" => "1", "name" => "Test"}})
      |> render_change()

      # Unit should be disabled (40 PV > 30 limit)
      html = render(new_live)
      assert html =~ "Exceeds PV"

      # Increase PV limit
      new_live
      |> form("#sortie-form", %{"sortie" => %{"pv_limit" => "50", "mission_number" => "1", "name" => "Test"}})
      |> render_change()

      # Unit should now be enabled (40 PV <= 50 limit)
      html = render(new_live)
      refute html =~ "Exceeds PV"
    end

    test "re-enables units when deployed units are removed", %{conn: conn, user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)

      # Create two units of 25 PV each
      master1 = master_unit_fixture(name: "Unit X", variant: "X-1", point_value: 25)
      master2 = master_unit_fixture(name: "Unit Y", variant: "Y-1", point_value: 25)

      unit1 = company_unit_fixture(company: company, master_unit: master1, custom_name: "UnitX")
      _unit2 = company_unit_fixture(company: company, master_unit: master2, custom_name: "UnitY")

      {:ok, new_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/new")

      # Set PV limit to 25 (only one unit can be deployed)
      new_live
      |> form("#sortie-form", %{"sortie" => %{"pv_limit" => "25", "mission_number" => "1", "name" => "Test"}})
      |> render_change()

      # Deploy first unit
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{unit1.id}']")
      |> render_click()

      # Second unit should be disabled
      html = render(new_live)
      assert html =~ "Exceeds PV"

      # Remove first unit
      new_live
      |> element("input[type=checkbox][phx-value-unit_id='#{unit1.id}']")
      |> render_click()

      # Second unit should now be enabled
      html = render(new_live)
      refute html =~ "Exceeds PV"
    end
  end
end