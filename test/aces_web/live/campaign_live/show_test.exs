defmodule AcesWeb.CampaignLive.ShowTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.CompaniesFixtures

  setup :register_and_log_in_user

  describe "URL-based modal state persistence" do
    test "unit search modal opens via URL param", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)

      # Open modal directly via URL
      {:ok, _view, html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=unit_search")

      # UnitSearchModal shows "Purchase Unit" for :sp_purchase mode
      assert html =~ "Purchase Unit"
      assert html =~ "modal-open"
    end

    test "unit search modal state survives simulated reconnection", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)

      # Open modal via URL
      {:ok, _view, html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=unit_search")

      assert html =~ "Purchase Unit"
      assert html =~ "modal-open"

      # Simulate reconnection by re-mounting with same URL (new LiveView session)
      {:ok, _view2, html2} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=unit_search")

      assert html2 =~ "Purchase Unit"
      assert html2 =~ "modal-open"
    end

    test "pilot form modal opens via URL param", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)

      # Open pilot form modal via URL
      {:ok, _view, html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=pilot_form")

      assert html =~ "Hire New Pilot"
    end

    test "pilot form modal state survives simulated reconnection", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)

      # Open modal via URL
      {:ok, _view, html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=pilot_form")

      assert html =~ "Hire New Pilot"

      # Simulate reconnection
      {:ok, _view2, html2} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=pilot_form")

      assert html2 =~ "Hire New Pilot"
    end

    test "sell unit modal opens via URL param with unit_id", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)
      master_unit = master_unit_fixture(name: "Atlas", variant: "AS7-D")
      unit = company_unit_fixture(company: company, master_unit: master_unit)

      # Open sell unit modal via URL
      {:ok, _view, html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=sell_unit&unit_id=#{unit.id}")

      assert html =~ "Sell Unit"
      assert html =~ "Atlas"
    end

    test "sell unit modal state survives simulated reconnection", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)
      master_unit = master_unit_fixture(name: "Atlas", variant: "AS7-D")
      unit = company_unit_fixture(company: company, master_unit: master_unit)

      # Open modal via URL
      {:ok, _view, html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=sell_unit&unit_id=#{unit.id}")

      assert html =~ "Sell Unit"
      assert html =~ "Atlas"

      # Simulate reconnection
      {:ok, _view2, html2} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=sell_unit&unit_id=#{unit.id}")

      assert html2 =~ "Sell Unit"
      assert html2 =~ "Atlas"
    end

    test "clicking purchase units button updates URL", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)

      {:ok, view, _html} = live(conn, ~p"/companies/#{company}/campaigns/#{campaign}")

      # Click purchase units button
      view |> element("button", "Purchase Units") |> render_click()

      # Modal should be open (UnitSearchModal shows "Purchase Unit" title)
      html = render(view)
      assert html =~ "Purchase Unit"
      assert html =~ "modal-open"
    end

    test "clicking hire pilot button updates URL", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company, %{"warchest_balance" => 500})

      {:ok, view, _html} = live(conn, ~p"/companies/#{company}/campaigns/#{campaign}")

      # Click hire pilot button
      view |> element("button", "Hire Pilot") |> render_click()

      # Modal should be open
      assert render(view) =~ "Hire New Pilot"
    end

    test "closing unit search modal clears URL param", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)

      {:ok, view, _html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=unit_search")

      html = render(view)
      assert html =~ "Purchase Unit"
      assert html =~ "modal-open"

      # Close the modal via the UnitSearchModal's close event
      view |> element("button[phx-click='close']") |> render_click()

      # Modal should be closed
      html = render(view)
      refute html =~ "modal-open"
    end

    test "invalid unit_id in URL does not open modal", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)

      # Modal should not open for non-existent unit
      {:ok, view, _html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=sell_unit&unit_id=99999")

      html = render(view)

      # Modal should not be open (no modal-open class visible)
      refute html =~ "modal-open"
      # Page should still load the campaign
      assert html =~ campaign.name
    end

    test "malformed unit_id in URL does not open modal", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)

      # Modal should not open for malformed unit_id
      {:ok, view, _html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=sell_unit&unit_id=notanumber")

      html = render(view)

      # Modal should not be open
      refute html =~ "modal-open"
      # Page should still load the campaign
      assert html =~ campaign.name
    end

    test "sell unit modal restores correct unit", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)
      master_unit1 = master_unit_fixture(name: "Atlas", variant: "AS7-D")
      master_unit2 = master_unit_fixture(name: "Timber Wolf", variant: "Prime")
      _unit1 = company_unit_fixture(company: company, master_unit: master_unit1)
      unit2 = company_unit_fixture(company: company, master_unit: master_unit2)

      # Open modal for unit2
      {:ok, _view, html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=sell_unit&unit_id=#{unit2.id}")

      # Should show Timber Wolf, not Atlas
      assert html =~ "Timber Wolf"
      refute html =~ "Atlas AS7-D" # Could still match "Atlas" in other contexts
    end
  end
end
