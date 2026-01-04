defmodule AcesWeb.UserSessionController do
  use AcesWeb, :controller

  alias Aces.Accounts
  alias AcesWeb.UserAuth

  def new(conn, _params) do
    email = get_in(conn.assigns, [:current_scope, Access.key(:user), Access.key(:email)])
    form = Phoenix.Component.to_form(%{"email" => email}, as: "user")

    render(conn, :new, form: form)
  end

  # email + password login
  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, "Welcome back!")
      |> UserAuth.log_in_user(user, user_params)
    else
      form = Phoenix.Component.to_form(user_params, as: "user")

      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> render(:new, form: form)
    end
  end

  def confirm(conn, %{"token" => token}) do
    case Accounts.confirm_user_email(token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email confirmed successfully! You can now log in with your password.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Email confirmation link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
