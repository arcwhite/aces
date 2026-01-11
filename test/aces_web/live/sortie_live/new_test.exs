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

      # Should redirect to campaign show page
      assert {:error, {:redirect, %{to: path}}} = result
      assert path == ~p"/companies/#{company.id}/campaigns/#{campaign.id}"

      # Verify the sortie was created
      campaign = Aces.Campaigns.get_campaign!(campaign.id)
      assert length(campaign.sorties) == 1

      sortie = List.first(campaign.sorties)
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
  end
end