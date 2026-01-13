defmodule AcesWeb.SortieLive.PersistenceTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.CompaniesFixtures
  import Aces.UnitsFixtures

  setup :register_and_log_in_user

  describe "Sortie damage and casualty persistence" do
    setup %{user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      pilot = pilot_fixture(company: company)
      master_unit = units_master_unit_fixture()
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)
      
      # Create sortie and deployment
      sortie = sortie_fixture(campaign: campaign)
      deployment = deployment_fixture(sortie: sortie, company_unit: company_unit, pilot: pilot)
      
      # Start the sortie
      sortie_with_deployments = Aces.Campaigns.get_sortie!(sortie.id)
      {:ok, sortie} = Aces.Campaigns.start_sortie(sortie_with_deployments, pilot.id)

      %{
        company: company,
        campaign: campaign,
        pilot: pilot,
        company_unit: company_unit,
        sortie: sortie,
        deployment: deployment
      }
    end

    test "damage status changes are persisted to database", %{conn: conn, company: company, campaign: campaign, sortie: sortie, deployment: deployment} do
      {:ok, show_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      # Update damage status
      show_live
      |> element("#damage-form-#{deployment.id}")
      |> render_change(%{"damage_status_#{deployment.id}" => "armor_damaged"})

      # Reload deployment from database to check persistence
      updated_deployment = Aces.Repo.get!(Aces.Campaigns.Deployment, deployment.id)
      assert updated_deployment.damage_status == "armor_damaged"

      # Update to a different status
      show_live
      |> element("#damage-form-#{deployment.id}")
      |> render_change(%{"damage_status_#{deployment.id}" => "crippled"})

      # Check persistence again
      updated_deployment2 = Aces.Repo.get!(Aces.Campaigns.Deployment, deployment.id)
      assert updated_deployment2.damage_status == "crippled"
    end

    test "pilot casualty changes are persisted to database", %{conn: conn, company: company, campaign: campaign, sortie: sortie, deployment: deployment} do
      {:ok, show_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      # Update pilot casualty status
      show_live
      |> element("#casualty-form-#{deployment.id}")
      |> render_change(%{"pilot_casualty_#{deployment.id}" => "wounded"})

      # Reload deployment from database to check persistence
      updated_deployment = Aces.Repo.get!(Aces.Campaigns.Deployment, deployment.id)
      assert updated_deployment.pilot_casualty == "wounded"

      # Update to killed status
      show_live
      |> element("#casualty-form-#{deployment.id}")
      |> render_change(%{"pilot_casualty_#{deployment.id}" => "killed"})

      # Check persistence again
      updated_deployment2 = Aces.Repo.get!(Aces.Campaigns.Deployment, deployment.id)
      assert updated_deployment2.pilot_casualty == "killed"
    end

    test "unnamed crew casualty changes are persisted to database", %{conn: conn, company: company, campaign: campaign, sortie: sortie, pilot: _pilot} do
      # Create deployment without pilot (unnamed crew)
      master_unit2 = units_master_unit_fixture()
      company_unit2 = company_unit_fixture(company: company, master_unit: master_unit2)
      crew_deployment = deployment_fixture(sortie: sortie, company_unit: company_unit2, pilot: nil)

      {:ok, show_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      # Update crew casualty status
      show_live
      |> element("#casualty-form-#{crew_deployment.id}")
      |> render_change(%{"pilot_casualty_#{crew_deployment.id}" => "wounded"})

      # Reload deployment from database to check persistence
      updated_deployment = Aces.Repo.get!(Aces.Campaigns.Deployment, crew_deployment.id)
      assert updated_deployment.pilot_casualty == "wounded"
      assert updated_deployment.pilot_id == nil  # Still unnamed crew
    end

    test "changes persist after page reload", %{conn: conn, company: company, campaign: campaign, sortie: sortie, deployment: deployment} do
      {:ok, show_live, _html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      # Make changes
      show_live
      |> element("#damage-form-#{deployment.id}")
      |> render_change(%{"damage_status_#{deployment.id}" => "structure_damaged"})

      show_live
      |> element("#casualty-form-#{deployment.id}")
      |> render_change(%{"pilot_casualty_#{deployment.id}" => "wounded"})

      # Simulate page reload by creating a new LiveView session
      {:ok, _new_live, html} = live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")

      # Check that the changes are shown in the new page load
      assert html =~ "structure_damaged\" selected"
      assert html =~ "wounded\" selected"
    end
  end
end