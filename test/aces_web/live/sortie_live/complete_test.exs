defmodule AcesWeb.SortieLive.CompleteTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.CompaniesFixtures
  import Aces.UnitsFixtures

  alias Aces.Campaigns

  setup :register_and_log_in_user

  describe "Sortie completion wizard" do
    setup %{user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      pilot = pilot_fixture(company: company, callsign: "Alpha")
      pilot2 = pilot_fixture(company: company, callsign: "Bravo")
      master_unit = units_master_unit_fixture()
      master_unit2 = master_unit_fixture()
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)
      company_unit2 = company_unit_fixture(company: company, master_unit: master_unit2)
      sortie = sortie_fixture(campaign: campaign)
      deployment = deployment_fixture(sortie: sortie, company_unit: company_unit, pilot: pilot)
      deployment2 = deployment_fixture(sortie: sortie, company_unit: company_unit2, pilot: pilot2)

      # Start the sortie and begin finalization
      sortie_with_deployments = Campaigns.get_sortie!(sortie.id)
      {:ok, started_sortie} = Campaigns.start_sortie(sortie_with_deployments, pilot.id)

      # Begin finalization (redirects to outcome step)
      {:ok, finalizing_sortie} =
        started_sortie
        |> Aces.Campaigns.Sortie.begin_finalization_changeset()
        |> Aces.Repo.update()

      %{
        company: company,
        campaign: campaign,
        pilot: pilot,
        pilot2: pilot2,
        company_unit: company_unit,
        company_unit2: company_unit2,
        sortie: finalizing_sortie,
        deployment: deployment,
        deployment2: deployment2
      }
    end

    test "outcome step renders correctly", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      {:ok, _live, html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/outcome")

      assert html =~ "Complete Sortie: Victory Details"
      assert html =~ "Mission Income"
      assert html =~ "Primary Objective"
      assert html =~ "Max SP Per Pilot"
    end

    test "outcome step saves and navigates to damage step", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      {:ok, live, _html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/outcome")

      # Fill in the form using the nested outcome params
      live
      |> form("form[phx-submit='save']", %{
        "outcome" => %{
          "primary_objective_income" => "500",
          "secondary_objectives_income" => "200",
          "waypoints_income" => "100",
          "sp_per_participating_pilot" => "50"
        }
      })
      |> render_change()

      # Submit and follow redirect
      {:ok, _damage_live, html} =
        live
        |> form("form[phx-submit='save']")
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Confirm Unit Status"
      assert html =~ "Deployed Units"

      # Verify sortie was updated
      updated_sortie = Campaigns.get_sortie!(sortie.id)
      assert updated_sortie.primary_objective_income == 500
      assert updated_sortie.secondary_objectives_income == 200
      assert updated_sortie.waypoints_income == 100
      assert updated_sortie.sp_per_participating_pilot == 50
      assert updated_sortie.finalization_step == "damage"
    end

    test "damage step renders correctly", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      # Advance to damage step
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{finalization_step: "damage"})
        |> Aces.Repo.update()

      {:ok, _live, html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/damage")

      assert html =~ "Confirm Unit Status"
      assert html =~ "Damage Status"
      assert html =~ "Casualty Status"
      assert html =~ "Salvageable"
    end

    test "damage step allows updating damage status", %{conn: conn, company: company, campaign: campaign, sortie: sortie, deployment: deployment} do
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{finalization_step: "damage"})
        |> Aces.Repo.update()

      {:ok, live, _html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/damage")

      # Update damage status - pass deployment_id in the params since phx-value-* isn't automatically included
      html =
        live
        |> element("select[phx-change='update_damage_status'][phx-value-deployment_id='#{deployment.id}']")
        |> render_change(%{"status" => "armor_damaged", "deployment_id" => to_string(deployment.id)})

      assert html =~ "armor_damaged\" selected"
    end

    test "damage step saves and navigates to costs step", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{finalization_step: "damage"})
        |> Aces.Repo.update()

      {:ok, live, _html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/damage")

      # Submit and follow redirect
      {:ok, _costs_live, html} =
        live
        |> element("button", "Continue to Costs")
        |> render_click()
        |> follow_redirect(conn)

      # HTML encodes & as &amp;
      assert html =~ "Costs &amp; Expenses"
      assert html =~ "Repair Costs"

      # Verify sortie was updated
      updated_sortie = Campaigns.get_sortie!(sortie.id)
      assert updated_sortie.finalization_step == "costs"
    end

    test "costs step renders correctly", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{finalization_step: "costs"})
        |> Aces.Repo.update()

      {:ok, _live, html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/costs")

      # HTML encodes & as &amp;
      assert html =~ "Costs &amp; Expenses"
      assert html =~ "Repair Costs"
      assert html =~ "Re-arming Costs"
      assert html =~ "Casualty Costs"
      assert html =~ "Financial Summary"
    end

    test "costs step calculates costs correctly", %{conn: conn, company: company, campaign: campaign, sortie: sortie, deployment: deployment} do
      # Set up sortie with income and damaged unit
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{
          finalization_step: "costs",
          primary_objective_income: 1000,
          secondary_objectives_income: 0,
          waypoints_income: 0
        })
        |> Aces.Repo.update()

      {:ok, _} =
        deployment
        |> Ecto.Changeset.change(%{damage_status: "armor_damaged", pilot_casualty: "wounded"})
        |> Aces.Repo.update()

      {:ok, _live, html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/costs")

      # Should show casualty cost of 100 for wounded pilot
      assert html =~ "100 SP"
      assert html =~ "Casualty Costs"
    end

    test "costs step saves and navigates to pilots step", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{
          finalization_step: "costs",
          primary_objective_income: 500
        })
        |> Aces.Repo.update()

      {:ok, live, _html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/costs")

      # Submit and follow redirect
      {:ok, _pilots_live, html} =
        live
        |> element("button", "Continue to Pilot SP")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "Pilot SP Distribution"
      assert html =~ "Select MVP"

      # Verify sortie was updated
      updated_sortie = Campaigns.get_sortie!(sortie.id)
      assert updated_sortie.finalization_step == "pilots"
    end

    test "pilots step renders correctly", %{conn: conn, company: company, campaign: campaign, sortie: sortie, pilot: pilot} do
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{
          finalization_step: "pilots",
          net_earnings: 500,
          sp_per_participating_pilot: 50
        })
        |> Aces.Repo.update()

      {:ok, _live, html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/pilots")

      assert html =~ "Pilot SP Distribution"
      assert html =~ pilot.name
      assert html =~ "Select MVP"
      # MVP bonus text appears in the explanation
      assert html =~ "additional 20 SP bonus"
    end

    test "pilots step allows MVP selection", %{conn: conn, company: company, campaign: campaign, sortie: sortie, pilot: pilot} do
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{
          finalization_step: "pilots",
          net_earnings: 500,
          sp_per_participating_pilot: 50
        })
        |> Aces.Repo.update()

      {:ok, live, _html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/pilots")

      # Select MVP
      html =
        live
        |> element("select[name='pilot_id']")
        |> render_change(%{"pilot_id" => to_string(pilot.id)})

      # Should show MVP bonus indicator for selected pilot
      assert html =~ "+20 MVP"
    end

    test "pilots step saves and navigates to spend_sp step", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{
          finalization_step: "pilots",
          net_earnings: 500,
          sp_per_participating_pilot: 50
        })
        |> Aces.Repo.update()

      {:ok, live, _html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/pilots")

      # Submit and follow redirect
      {:ok, _spend_sp_live, html} =
        live
        |> element("button", "Continue to Spend SP")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "Spend SP"

      # Verify sortie was updated
      updated_sortie = Campaigns.get_sortie!(sortie.id)
      assert updated_sortie.finalization_step == "spend_sp"
    end

    test "spend_sp step renders correctly", %{conn: conn, company: company, campaign: campaign, sortie: sortie, pilot: pilot} do
      # Need pilots to have earned SP
      {:ok, _} =
        pilot
        |> Ecto.Changeset.change(%{sp_available: 50, sp_earned: 50})
        |> Aces.Repo.update()

      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{
          finalization_step: "spend_sp",
          net_earnings: 500,
          sp_per_participating_pilot: 50
        })
        |> Aces.Repo.update()

      {:ok, _live, html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/spend_sp")

      assert html =~ "Spend SP"
      assert html =~ "Skill Training"
      assert html =~ "Edge Tokens"
      assert html =~ "Edge Abilities"
    end

    test "spend_sp step saves and navigates to summary step", %{conn: conn, company: company, campaign: campaign, sortie: sortie, pilot: pilot, pilot2: pilot2} do
      # Ensure all pilots have sp_available = 0 (no SP to spend)
      {:ok, _} =
        pilot
        |> Ecto.Changeset.change(%{sp_available: 0})
        |> Aces.Repo.update()

      {:ok, _} =
        pilot2
        |> Ecto.Changeset.change(%{sp_available: 0})
        |> Aces.Repo.update()

      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{
          finalization_step: "spend_sp",
          net_earnings: 500
        })
        |> Aces.Repo.update()

      {:ok, live, _html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/spend_sp")

      # Submit and follow redirect (no pilots with SP to spend, so button should be enabled)
      {:ok, _summary_live, html} =
        live
        |> element("button", "Continue to Summary")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "Complete Sortie: Summary"
      assert html =~ "Warchest Update"

      # Verify sortie was updated
      updated_sortie = Campaigns.get_sortie!(sortie.id)
      assert updated_sortie.finalization_step == "summary"
    end

    test "summary step renders correctly", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{
          finalization_step: "summary",
          primary_objective_income: 500,
          total_income: 500,
          total_expenses: 100,
          net_earnings: 400
        })
        |> Aces.Repo.update()

      {:ok, _live, html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/summary")

      assert html =~ "Complete Sortie: Summary"
      assert html =~ "Financial Summary"
      assert html =~ "Warchest Update"
      assert html =~ "Complete Sortie"
    end

    test "summary step completes sortie and updates warchest", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      initial_warchest = campaign.warchest_balance || 0

      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{
          finalization_step: "summary",
          net_earnings: 400
        })
        |> Aces.Repo.update()

      {:ok, live, _html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/summary")

      # Complete the sortie
      {:ok, _campaign_live, html} =
        live
        |> element("button", "Complete Sortie")
        |> render_click()
        |> follow_redirect(conn)

      # Should show campaign page
      assert html =~ campaign.name

      # Verify sortie status
      updated_sortie = Campaigns.get_sortie!(sortie.id)
      assert updated_sortie.status == "completed"
      assert updated_sortie.was_successful == true
      assert updated_sortie.completed_at != nil
      assert updated_sortie.finalization_step == nil

      # Verify warchest was updated
      updated_campaign = Campaigns.get_campaign!(campaign.id)
      assert updated_campaign.warchest_balance == initial_warchest + 400
    end

    test "redirects when trying to skip steps", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      # Sortie is at outcome step, try to skip ahead to summary
      {:ok, _live, html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/summary")
        |> follow_redirect(conn)

      # Should redirect to outcome step (can't skip from outcome to summary)
      assert html =~ "Complete Sortie: Victory Details"
    end

    test "allows backward navigation", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      # Advance sortie to costs step
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{finalization_step: "costs"})
        |> Aces.Repo.update()

      # Should be able to go back to damage step
      {:ok, _live, html} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/damage")

      assert html =~ "Confirm Unit Status"
    end

    test "summary step redirects to show page for completed sorties", %{conn: conn, company: company, campaign: campaign, sortie: sortie} do
      # Mark sortie as completed with truncated timestamp
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{
          status: "completed",
          was_successful: true,
          completed_at: DateTime.truncate(DateTime.utc_now(), :second),
          finalization_step: nil,
          net_earnings: 400
        })
        |> Aces.Repo.update()

      # Summary page now redirects to show page for completed sorties
      {:error, {:live_redirect, %{to: redirect_path}}} =
        live(conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/summary")

      assert redirect_path =~ "/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}"
      refute redirect_path =~ "/complete/summary"

      # The show page displays the full summary for completed sorties
      {:ok, _live, html} = live(conn, redirect_path)
      assert html =~ "Sortie Completed - Victory!"
      assert html =~ "Mission Details"
      assert html =~ "Financial Summary"
      assert html =~ "Back to"
      refute html =~ ">Complete Sortie<"
    end
  end

  describe "Wizard step authorization" do
    setup %{user: user} do
      company = company_fixture(user: user)
      campaign = campaign_fixture(company)
      pilot = pilot_fixture(company: company)
      master_unit = units_master_unit_fixture()
      company_unit = company_unit_fixture(company: company, master_unit: master_unit)
      sortie = sortie_fixture(campaign: campaign)
      _deployment = deployment_fixture(sortie: sortie, company_unit: company_unit, pilot: pilot)

      # Start and begin finalization
      sortie_with_deployments = Campaigns.get_sortie!(sortie.id)
      {:ok, started_sortie} = Campaigns.start_sortie(sortie_with_deployments, pilot.id)

      {:ok, finalizing_sortie} =
        started_sortie
        |> Aces.Campaigns.Sortie.begin_finalization_changeset()
        |> Aces.Repo.update()

      %{
        company: company,
        campaign: campaign,
        sortie: finalizing_sortie
      }
    end

    test "denies access to non-owner", %{company: company, campaign: campaign, sortie: sortie} do
      # Create a different user
      other_user = Aces.AccountsFixtures.user_fixture()
      other_conn = Phoenix.ConnTest.build_conn()
      other_conn = log_in_user(other_conn, other_user)

      # Non-owner is redirected via live_redirect (within the app)
      {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
        live(other_conn, ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}/complete/outcome")

      assert redirect_to =~ "/companies/#{company.id}"
      assert flash["error"] =~ "permission"
    end
  end
end
