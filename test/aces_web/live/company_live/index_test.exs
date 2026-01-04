defmodule AcesWeb.CompanyLive.IndexTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures

  setup :register_and_log_in_user

  describe "Index page" do
    test "lists all user's companies", %{conn: conn, user: user} do
      _company1 = company_fixture(user: user, name: "Alpha Company")
      _company2 = company_fixture(user: user, name: "Beta Company")
      _other_company = company_fixture(name: "Other Company")

      {:ok, _index_live, html} = live(conn, ~p"/companies")

      assert html =~ "My Mercenary Companies"
      assert html =~ "Alpha Company"
      assert html =~ "Beta Company"
      refute html =~ "Other Company"
    end

    test "shows empty state when user has no companies", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/companies")

      assert html =~ "You don&#39;t have any companies yet"
      assert html =~ "Create your first mercenary company to get started"
    end

    test "displays company stats", %{conn: conn, user: user} do
      company = company_fixture(user: user, warchest_balance: 5000)
      company_unit_fixture(company: company)
      company_unit_fixture(company: company)

      {:ok, _index_live, html} = live(conn, ~p"/companies")

      assert html =~ company.name
      # unit count
      assert html =~ "2"
      # warchest
      assert html =~ "5000 SP"
    end

    test "shows create new company button", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/companies")

      assert html =~ "Create New Company"
    end

    test "deletes company when user is owner", %{conn: conn, user: user} do
      company = company_fixture(user: user)

      {:ok, index_live, _html} = live(conn, ~p"/companies")

      assert index_live
             |> element("button[phx-click='delete'][phx-value-id='#{company.id}']")
             |> render_click()

      refute has_element?(index_live, "#company-#{company.id}")
    end

    test "prevents unauthorized access when not logged in", %{conn: conn} do
      conn = conn |> log_out_user()
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/companies")

      assert path == ~p"/users/log-in"
    end
  end

  describe "Navigation" do
    test "can navigate to new company page", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/companies")

      assert index_live
             |> element("a[href='/companies/new']")
             |> render_click()
    end

    test "can navigate to company show page", %{conn: conn, user: user} do
      company = company_fixture(user: user)

      {:ok, index_live, _html} = live(conn, ~p"/companies")

      assert index_live
             |> element("a[href='/companies/#{company.id}']")
             |> render_click()
    end
  end

  defp log_out_user(conn) do
    Plug.Conn.delete_session(conn, :user_token)
  end
end
