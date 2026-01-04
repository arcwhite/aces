defmodule AcesWeb.UserAuthLive do
  @moduledoc """
  LiveView authentication hooks
  """

  use AcesWeb, :verified_routes
  import Phoenix.LiveView
  import Phoenix.Component

  alias Aces.Accounts

  def on_mount(:default, _params, session, socket) do
    socket = assign_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:allow_unauthenticated, _params, session, socket) do
    {:cont, assign_current_scope(socket, session)}
  end

  defp assign_current_scope(socket, session) do
    case session do
      %{"user_token" => user_token} ->
        case Accounts.get_user_by_session_token(user_token) do
          nil ->
            assign(socket, :current_scope, nil)

          {user, _authenticated_at} ->
            scope = Accounts.Scope.for_user(user)
            assign(socket, :current_scope, scope)

          user when is_struct(user) ->
            scope = Accounts.Scope.for_user(user)
            assign(socket, :current_scope, scope)
        end

      _ ->
        assign(socket, :current_scope, nil)
    end
  end
end
