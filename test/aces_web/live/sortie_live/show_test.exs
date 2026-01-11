defmodule AcesWeb.SortieLive.ShowTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  # import Aces.AccountsFixtures - not used
  import Aces.CompaniesFixtures
  import Aces.UnitsFixtures

  setup :register_and_log_in_user

  describe "Show sortie page" do
    setup %{user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      pilot = pilot_fixture(company: company)
      master_unit = units_master_unit_fixture()
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)
      sortie = sortie_fixture(campaign: campaign)
      deployment = deployment_fixture(sortie: sortie, company_unit: company_unit, pilot: pilot)

      %{
        company: company, 
        campaign: campaign, 
        pilot: pilot, 
        company_unit: company_unit,
        sortie: sortie,
        deployment: deployment
      }
    end

    test "renders sortie show page", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      assert html =~ "Sortie #{sortie.mission_number}"
      assert html =~ sortie.name
      assert html =~ "Deployment Status"
      assert html =~ "PV Limit"
    end

    test "shows deployment information", %{conn: conn, company: company, campaign: campaign, sortie: sortie, deployment: deployment} do
      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      assert html =~ deployment.company_unit.master_unit.name
      assert html =~ deployment.pilot.name
      assert html =~ "#{deployment.company_unit.master_unit.point_value} PV"
    end

    test "allows damage status updates for in-progress sortie", %{conn: conn, company: company, campaign: campaign, pilot: pilot, company_unit: company_unit} do
      # Create a sortie and deployment first
      sortie = sortie_fixture(campaign: campaign)
      deployment = deployment_fixture(sortie: sortie, company_unit: company_unit, pilot: pilot)
      
      # Reload sortie with deployments and start it
      sortie_with_deployments = Aces.Campaigns.get_sortie!(sortie.id)
      {:ok, sortie} = Aces.Campaigns.start_sortie(sortie_with_deployments, pilot.id)

      {:ok, show_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      # Update damage status
      show_live
      |> element("#damage-form-#{deployment.id}")
      |> render_change(%{"damage_status_#{deployment.id}" => "armor_damaged"})

      # Check that damage status was updated in the UI
      html = render(show_live)
      assert html =~ "armor_damaged\" selected"
    end

    test "allows pilot casualty updates for in-progress sortie", %{conn: conn, company: company, campaign: campaign, pilot: pilot, company_unit: company_unit} do
      # Create a sortie and deployment first
      sortie = sortie_fixture(campaign: campaign)
      deployment = deployment_fixture(sortie: sortie, company_unit: company_unit, pilot: pilot)
      
      # Reload sortie with deployments and start it
      sortie_with_deployments = Aces.Campaigns.get_sortie!(sortie.id)
      {:ok, sortie} = Aces.Campaigns.start_sortie(sortie_with_deployments, pilot.id)

      {:ok, show_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      # Update pilot casualty status
      show_live
      |> element("#casualty-form-#{deployment.id}")
      |> render_change(%{"pilot_casualty_#{deployment.id}" => "wounded"})

      # Check that casualty status was updated in the UI
      html = render(show_live)
      assert html =~ "wounded\" selected"
    end

    test "prevents damage updates for non-in-progress sorties", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      # Sortie is in setup status by default
      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      # Should show badges instead of forms with selects for non in-progress sorties
      assert html =~ ~s|<div class="badge|
      refute html =~ ~s|<form phx-change|
    end

    test "shows mission in progress alert for in-progress sortie", %{conn: conn, company: company, campaign: campaign, pilot: pilot, company_unit: company_unit} do
      # Create a sortie and deployment first
      sortie = sortie_fixture(campaign: campaign)
      _deployment = deployment_fixture(sortie: sortie, company_unit: company_unit, pilot: pilot)
      
      # Reload sortie with deployments and start it
      sortie_with_deployments = Aces.Campaigns.get_sortie!(sortie.id)
      {:ok, sortie} = Aces.Campaigns.start_sortie(sortie_with_deployments, pilot.id)

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      assert html =~ "Mission in progress"
      assert html =~ "Mark unit damage and pilot casualties"
    end

    test "allows casualty updates for unnamed crew", %{conn: conn, company: company, campaign: campaign, pilot: pilot, company_unit: company_unit} do
      # Create a second unit for the pilot deployment
      master_unit2 = master_unit_fixture()
      company_unit2 = company_unit_fixture(company: company, master_unit: master_unit2)
      
      # Create a sortie and deployment without a pilot (unnamed crew)
      sortie = sortie_fixture(campaign: campaign)
      deployment = deployment_fixture(sortie: sortie, company_unit: company_unit, pilot: nil)
      
      # Add a deployment with a pilot to allow starting the sortie
      _pilot_deployment = deployment_fixture(sortie: sortie, company_unit: company_unit2, pilot: pilot)
      
      # Reload sortie with deployments and start it
      sortie_with_deployments = Aces.Campaigns.get_sortie!(sortie.id)
      {:ok, sortie} = Aces.Campaigns.start_sortie(sortie_with_deployments, pilot.id)

      {:ok, show_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      # Update crew casualty status
      show_live
      |> element("#casualty-form-#{deployment.id}")
      |> render_change(%{"pilot_casualty_#{deployment.id}" => "wounded"})

      # Check that casualty status was updated in the UI for unnamed crew
      html = render(show_live)
      assert html =~ "wounded\" selected"
    end
  end
end