defmodule AcesWeb.CampaignLive.IndexTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.CompaniesFixtures

  alias Aces.Campaigns

  setup :register_and_log_in_user

  describe "Campaigns index page" do
    test "renders campaigns page with tabs", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      _campaign = campaign_fixture(company)

      {:ok, _index_live, html} = live(conn, ~p"/campaigns")

      assert html =~ "My Campaigns"
      assert html =~ "Active"
      assert html =~ "Past"
    end

    test "shows active campaigns on active tab", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      _campaign = campaign_fixture(company, %{"name" => "Active Campaign"})

      {:ok, _index_live, html} = live(conn, ~p"/campaigns")

      # Active tab should be selected by default and show the campaign
      assert html =~ "Active Campaign"
      assert html =~ "badge-success"
    end

    test "shows past campaigns on past tab", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company, %{"name" => "Completed Campaign"})
      {:ok, _completed} = Campaigns.complete_campaign(campaign, "completed")

      {:ok, index_live, html} = live(conn, ~p"/campaigns")

      # Active tab should not show completed campaign
      refute html =~ "Completed Campaign"

      # Click on past tab
      html = index_live |> element("button", "Past") |> render_click()

      # Past tab should show the completed campaign
      assert html =~ "Completed Campaign"
      assert html =~ "Completed"

      # Wait for any PubSub-triggered reloads to complete
      render(index_live)
    end

    test "shows failed campaigns on past tab", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company, %{"name" => "Failed Campaign"})
      {:ok, _failed} = Campaigns.complete_campaign(campaign, "failed")

      {:ok, index_live, _html} = live(conn, ~p"/campaigns")

      # Click on past tab
      html = index_live |> element("button", "Past") |> render_click()

      # Past tab should show the failed campaign
      assert html =~ "Failed Campaign"
      assert html =~ "Failed"

      # Wait for any PubSub-triggered reloads to complete
      render(index_live)
    end

    test "shows campaign count badges", %{conn: conn, user: user} do
      # Use multiple companies since each company can only have one active campaign
      company1 = company_fixture(user: user, status: "active", name: "Company 1")
      company2 = company_fixture(user: user, status: "active", name: "Company 2")
      company3 = company_fixture(user: user, status: "active", name: "Company 3")

      # Create 2 active campaigns (in different companies)
      campaign_fixture(company1, %{"name" => "Active 1"})
      campaign_fixture(company2, %{"name" => "Active 2"})

      # Create 1 completed campaign
      campaign = campaign_fixture(company3, %{"name" => "Past 1"})
      {:ok, _} = Campaigns.complete_campaign(campaign, "completed")

      {:ok, _index_live, html} = live(conn, ~p"/campaigns")

      # Should show count badges in tabs
      assert html =~ "<span class=\"badge badge-sm badge-primary ml-2\">2</span>"
      assert html =~ "<span class=\"badge badge-sm badge-ghost ml-2\">1</span>"
    end

    test "switches between tabs correctly", %{conn: conn, user: user} do
      # Use two companies since each can only have one active campaign
      company1 = company_fixture(user: user, status: "active", name: "Company Active")
      company2 = company_fixture(user: user, status: "active", name: "Company Past")

      campaign_fixture(company1, %{"name" => "Active Test"})
      past = campaign_fixture(company2, %{"name" => "Past Test"})
      {:ok, _} = Campaigns.complete_campaign(past, "completed")

      {:ok, index_live, html} = live(conn, ~p"/campaigns")

      # Initially on active tab
      assert html =~ "Active Test"
      refute html =~ "Past Test"

      # Switch to past tab
      html = index_live |> element("button", "Past") |> render_click()
      assert html =~ "Past Test"
      refute html =~ "Active Test"

      # Switch back to active tab
      html = index_live |> element("button", "Active") |> render_click()
      assert html =~ "Active Test"
      refute html =~ "Past Test"

      # Wait for any PubSub-triggered reloads to complete
      render(index_live)
    end

    test "shows empty state for active campaigns", %{conn: conn, user: _user} do
      {:ok, _index_live, html} = live(conn, ~p"/campaigns")

      assert html =~ "No Active Campaigns"
      assert html =~ "Go to Companies"
    end

    test "shows empty state for past campaigns", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign_fixture(company, %{"name" => "Only Active"})

      {:ok, index_live, _html} = live(conn, ~p"/campaigns")

      # Click on past tab
      html = index_live |> element("button", "Past") |> render_click()

      assert html =~ "No Past Campaigns"
      assert html =~ "Completed and failed campaigns will appear here"

      # Wait for any PubSub-triggered reloads to complete
      render(index_live)
    end

    test "shows completion date for past campaigns", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company, %{"name" => "Dated Campaign"})
      {:ok, _} = Campaigns.complete_campaign(campaign, "completed")

      {:ok, index_live, _html} = live(conn, ~p"/campaigns")

      # Click on past tab
      html = index_live |> element("button", "Past") |> render_click()

      # Should show completed date
      assert html =~ "Completed:"

      # Wait for any PubSub-triggered reloads to complete
      render(index_live)
    end

    test "shows campaigns from multiple companies", %{conn: conn, user: user} do
      company1 = company_fixture(user: user, status: "active", name: "Company One")
      company2 = company_fixture(user: user, status: "active", name: "Company Two")

      campaign_fixture(company1, %{"name" => "Campaign Company One"})
      campaign_fixture(company2, %{"name" => "Campaign Company Two"})

      {:ok, _index_live, html} = live(conn, ~p"/campaigns")

      assert html =~ "Campaign Company One"
      assert html =~ "Campaign Company Two"
      assert html =~ "Company One"
      assert html =~ "Company Two"
    end

    test "redirects to login when not authenticated" do
      conn = build_conn()
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/campaigns")

      assert path == ~p"/users/log-in"
    end
  end
end
