defmodule AcesWeb.CompanyLive.NewTest do
  use AcesWeb.ConnCase

  import Phoenix.LiveViewTest
  import Aces.AccountsFixtures

  setup :register_and_log_in_user

  describe "New company page" do
    test "renders new company form", %{conn: conn} do
      {:ok, _new_live, html} = live(conn, ~p"/companies/new")

      assert html =~ "Create New Company"
      assert html =~ "Company Name"
      assert html =~ "Description"
      assert html =~ "Starting Warchest"
    end

    test "creates company with valid data and redirects to draft setup", %{conn: conn, user: user} do
      {:ok, new_live, _html} = live(conn, ~p"/companies/new")

      form_data = %{
        "company" => %{
          "name" => "New Mercenary Company",
          "description" => "A brand new company",
          "warchest_balance" => "3000"
        }
      }

      result =
        new_live
        |> form("#company-form", form_data)
        |> render_submit()

      # Should redirect to draft setup page
      assert {:error, {:live_redirect, %{to: path}}} = result
      assert String.contains?(path, "/draft")

      # Verify the company was created in draft status
      company = Aces.Companies.list_user_companies(user) |> List.first()
      assert company.name == "New Mercenary Company"
      assert company.description == "A brand new company"
      assert company.warchest_balance == 3000
      assert company.status == "draft"
      assert company.pv_budget == 400
    end

    test "shows validation errors with invalid data", %{conn: conn} do
      {:ok, new_live, _html} = live(conn, ~p"/companies/new")

      form_data = %{
        "company" => %{
          "name" => "",
          "warchest_balance" => "-100"
        }
      }

      html =
        new_live
        |> form("#company-form", form_data)
        |> render_change()

      assert html =~ "can&#39;t be blank"
      assert html =~ "must be greater than or equal to 0"
    end

    test "validates as user types", %{conn: conn} do
      {:ok, new_live, _html} = live(conn, ~p"/companies/new")

      # Empty name should show error
      html =
        new_live
        |> form("#company-form", %{"company" => %{"name" => ""}})
        |> render_change()

      assert html =~ "can&#39;t be blank"

      # Valid name should clear error
      html =
        new_live
        |> form("#company-form", %{"company" => %{"name" => "Valid Name"}})
        |> render_change()

      refute html =~ "can&#39;t be blank"
    end

    test "has back to companies link", %{conn: conn} do
      {:ok, _new_live, html} = live(conn, ~p"/companies/new")

      assert html =~ "Back to Companies"
      assert html =~ ~p"/companies"
    end

    test "prevents unauthorized access when not logged in", %{conn: conn} do
      conn = conn |> log_out_user()
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/companies/new")

      assert path == ~p"/users/log-in"
    end
  end

  defp log_out_user(conn) do
    Plug.Conn.delete_session(conn, :user_token)
  end
end
