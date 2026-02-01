defmodule AcesWeb.UserRegistrationController do
  use AcesWeb, :controller

  alias Aces.Accounts

  def new(conn, params) do
    # Store redirect_to in session so login after registration will redirect back
    conn =
      case params["redirect_to"] do
        nil -> conn
        redirect_to -> put_session(conn, :user_return_to, redirect_to)
      end

    changeset = Accounts.change_user_registration()
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_user_confirmation_instructions(
            user,
            &url(~p"/users/confirm/#{&1}")
          )

        conn
        |> put_flash(
          :info,
          "Account created successfully! Please check your email to confirm your account."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)
    end
  end
end
