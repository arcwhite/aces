defmodule AcesWeb.UserRegistrationController do
  use AcesWeb, :controller

  alias Aces.Accounts
  alias Aces.Accounts.User

  def new(conn, _params) do
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
