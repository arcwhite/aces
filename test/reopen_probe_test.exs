defmodule ReopenProbeTest do
  use AcesWeb.ConnCase
  import Phoenix.LiveViewTest
  import Aces.CompaniesFixtures
  import Aces.UnitsFixtures

  setup :register_and_log_in_user

  test "default listing survives close/reopen", %{conn: conn, user: user} do
    company = company_fixture(user: user, status: "active")
    campaign = campaign_fixture(company)
    _atlas = atlas_master_unit_fixture()

    {:ok, view, html} =
      live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=unit_search")

    assert html =~ ~s(data-role="results-list")

    # simulate the component's own close event
    render_click(view |> element("#unit-search button[phx-click=close]"))

    {:ok, _view2, html2} =
      live(conn, ~p"/companies/#{company}/campaigns/#{campaign}?modal=unit_search")
    assert html2 =~ ~s(data-role="results-list")

    # same LiveView instance, reopen via patch
    html3 = render_patch(view, ~p"/companies/#{company}/campaigns/#{campaign}?modal=unit_search")
    IO.puts("REOPEN has results-list? #{html3 =~ ~s(data-role="results-list")}")
    IO.puts("REOPEN has empty-idle? #{html3 =~ ~s(data-role="results-empty-idle")}")
  end
end
