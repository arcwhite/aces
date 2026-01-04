defmodule AcesWeb.UserResetPasswordController do
  use AcesWeb, :controller

  alias Aces.Accounts

  def new(conn, _params) do
    render(conn, :new)
  end

  def create(conn, %{"user" => %{"email" => email}}) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_reset_password_instructions(
        user,
        &url(~p"/users/reset-password/#{&1}")
      )
    end

    conn
    |> put_flash(
      :info,
      "If your email is in our system, you will receive instructions to reset your password shortly."
    )
    |> redirect(to: ~p"/users/log-in")
  end

  def edit(conn, %{"token" => token}) do
    if user = Accounts.get_user_by_reset_password_token(token) do
      changeset = Accounts.change_user_password(user)

      conn
      |> assign(:user, user)
      |> assign(:token, token)
      |> render(:edit, changeset: changeset)
    else
      conn
      |> put_flash(:error, "Reset password link is invalid or it has expired.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def update(conn, %{"token" => token, "user" => user_params}) do
    if user = Accounts.get_user_by_reset_password_token(token) do
      case Accounts.reset_user_password(user, user_params) do
        {:ok, _} ->
          conn
          |> put_flash(:info, "Password reset successfully. You can now log in with your new password.")
          |> redirect(to: ~p"/users/log-in")

        {:error, changeset} ->
          conn
          |> assign(:user, user)
          |> assign(:token, token)
          |> render(:edit, changeset: changeset)
      end
    else
      conn
      |> put_flash(:error, "Reset password link is invalid or it has expired.")
      |> redirect(to: ~p"/users/log-in")
    end
  end
end
