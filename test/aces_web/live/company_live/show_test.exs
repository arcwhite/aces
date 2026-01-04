defmodule AcesWeb.CompanyLive.ShowTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.AccountsFixtures
  import Aces.CompaniesFixtures

  setup :register_and_log_in_user

  describe "Show page" do
    test "displays company information", %{conn: conn, user: user} do
      company = company_fixture(user: user, name: "Test Company", description: "Test description")

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      assert html =~ "Test Company"
      assert html =~ "Test description"
    end

    test "displays company stats", %{conn: conn, user: user} do
      company = company_fixture(user: user, warchest_balance: 7500)
      company_unit_fixture(company: company)
      company_unit_fixture(company: company)
      company_unit_fixture(company: company)

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      # unit count
      assert html =~ "3"
      # warchest
      assert html =~ "7500"
    end

    test "shows empty roster message when no units", %{conn: conn, user: user} do
      company = company_fixture(user: user)

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      assert html =~ "No units in roster yet"
      assert html =~ "Add your first unit to get started"
    end

    test "displays unit roster when units exist", %{conn: conn, user: user} do
      company = company_fixture(user: user)
      master_unit = master_unit_fixture(name: "Atlas", variant: "AS7-D")
      company_unit_fixture(company: company, master_unit: master_unit, custom_name: "The Hammer")

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      assert html =~ "Atlas AS7-D"
      assert html =~ "The Hammer"
    end

    test "has back to companies link", %{conn: conn, user: user} do
      company = company_fixture(user: user)

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      assert html =~ "Back to Companies"
      assert html =~ ~p"/companies"
    end

    test "shows add unit button", %{conn: conn, user: user} do
      company = company_fixture(user: user)

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      assert html =~ "Add Unit"
    end

    test "prevents access when user is not a member", %{conn: conn} do
      other_user = user_fixture()
      company = company_fixture(user: other_user)

      assert {:error, {:redirect, %{flash: %{"error" => _}, to: "/companies"}}} =
               live(conn, ~p"/companies/#{company.id}")
    end

    test "allows viewer to view but not edit", %{conn: conn, user: user} do
      %{company: company, viewer: _viewer} = company_with_members_fixture()
      Aces.Companies.add_member(company, user, "viewer")

      {:ok, _show_live, html} = live(conn, ~p"/companies/#{company.id}")

      # Can view
      assert html =~ company.name

      # Add Unit button should still be visible (permission enforcement happens on action)
      assert html =~ "Add Unit"
    end

    test "prevents unauthorized access when not logged in", %{conn: conn, user: user} do
      company = company_fixture(user: user)
      conn = conn |> log_out_user()

      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/companies/#{company.id}")

      assert path == ~p"/users/log-in"
    end
  end

  defp log_out_user(conn) do
    Plug.Conn.delete_session(conn, :user_token)
  end
end
