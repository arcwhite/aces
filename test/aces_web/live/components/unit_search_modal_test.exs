defmodule AcesWeb.Components.UnitSearchModalTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.CompaniesFixtures
  import Aces.UnitsFixtures

  setup :register_and_log_in_user

  # The modal renders one of five mutually-exclusive result states, each tagged
  # with a `data-role` attribute. Asserting on these hooks decouples the tests
  # from copy tweaks (and HTML-entity encoding of user text like the search
  # term inside the empty state).
  describe "result-state data-role hooks" do
    test "renders results-list when the local cache has units", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)

      # A cached unit populates the default results loaded on modal open.
      _atlas = atlas_master_unit_fixture()

      {:ok, _view, html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=unit_search")

      assert html =~ ~s(data-role="results-list")
      refute html =~ ~s(data-role="results-empty-idle")
    end

    test "renders results-empty-idle when the cache is empty and no search term", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)

      {:ok, _view, html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=unit_search")

      assert html =~ ~s(data-role="results-empty-idle")
      refute html =~ ~s(data-role="results-list")
    end

    test "renders results-empty-search when a 2+ char search matches nothing", %{conn: conn, user: user} do
      company = company_fixture(user: user, status: "active")
      campaign = campaign_fixture(company)

      {:ok, view, _html} =
        live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=unit_search")

      html =
        view
        |> element("input[name=search]")
        |> render_keyup(%{"value" => "zz-no-match-zz"})

      assert html =~ ~s(data-role="results-empty-search")
      refute html =~ ~s(data-role="results-list")
    end
  end
end
