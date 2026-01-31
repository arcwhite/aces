defmodule AcesWeb.InvitationLive.Accept do
  @moduledoc """
  LiveView for accepting company invitations via token URL.

  This page handles both authenticated and unauthenticated users:
  - Authenticated users with matching email can accept directly
  - Authenticated users with non-matching email see an error
  - Unauthenticated users are prompted to log in or register
  """
  use AcesWeb, :live_view

  alias Aces.{Accounts, Companies}

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Companies.get_invitation_by_token(token) do
      {:ok, invitation} ->
        socket =
          socket
          |> assign(:page_title, "Accept Invitation")
          |> assign(:invitation, invitation)
          |> assign(:token, token)
          |> check_user_state()

        {:ok, socket}

      {:error, :invalid_token} ->
        {:ok,
         socket
         |> assign(:page_title, "Invalid Invitation")
         |> assign(:invitation, nil)
         |> assign(:token, token)
         |> assign(:state, :invalid)}
    end
  end

  defp check_user_state(socket) do
    invitation = socket.assigns.invitation
    current_scope = socket.assigns[:current_scope]

    cond do
      # No user logged in
      is_nil(current_scope) || is_nil(current_scope.user) ->
        # Check if user exists
        existing_user = Accounts.get_user_by_email(invitation.invited_email)
        assign(socket, :state, if(existing_user, do: :needs_login, else: :needs_registration))

      # User logged in but email doesn't match
      String.downcase(current_scope.user.email) != String.downcase(invitation.invited_email) ->
        assign(socket, :state, :email_mismatch)

      # User logged in and email matches
      true ->
        assign(socket, :state, :can_accept)
    end
  end

  @impl true
  def handle_event("accept", _params, socket) do
    invitation = socket.assigns.invitation
    user = socket.assigns.current_scope.user

    case Companies.accept_invitation(invitation, user) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> put_flash(:info, "You have joined #{invitation.company.name}!")
         |> redirect(to: ~p"/companies/#{invitation.company.id}")}

      {:error, :email_mismatch} ->
        {:noreply, put_flash(socket, :error, "This invitation is for a different email address.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to accept invitation. Please try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-2xl">
      <%= case @state do %>
        <% :invalid -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body text-center">
              <h1 class="text-3xl font-bold text-error mb-4">Invalid Invitation</h1>
              <p class="mb-4">
                This invitation link is invalid, has expired, or has already been used.
              </p>
              <div class="card-actions justify-center">
                <.link navigate={~p"/companies"} class="btn btn-primary">
                  Go to Companies
                </.link>
              </div>
            </div>
          </div>

        <% :needs_login -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h1 class="text-3xl font-bold mb-4">Company Invitation</h1>

              <div class="alert alert-info mb-4">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  class="stroke-current shrink-0 w-6 h-6"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                  >
                  </path>
                </svg>
                <span>Please log in to accept this invitation.</span>
              </div>

              <.render_invitation_details invitation={@invitation} />

              <div class="card-actions justify-center mt-6">
                <.link
                  href={~p"/users/log-in?#{[redirect_to: ~p"/invitations/#{@token}"]}"}
                  class="btn btn-primary"
                >
                  Log In
                </.link>
              </div>
            </div>
          </div>

        <% :needs_registration -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h1 class="text-3xl font-bold mb-4">Company Invitation</h1>

              <div class="alert alert-info mb-4">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  class="stroke-current shrink-0 w-6 h-6"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                  >
                  </path>
                </svg>
                <span>
                  Create an account with the email <strong>{@invitation.invited_email}</strong>
                  to accept this invitation.
                </span>
              </div>

              <.render_invitation_details invitation={@invitation} />

              <div class="card-actions justify-center mt-6">
                <.link
                  href={~p"/users/register?#{[redirect_to: ~p"/invitations/#{@token}"]}"}
                  class="btn btn-primary"
                >
                  Create Account
                </.link>
              </div>
            </div>
          </div>

        <% :email_mismatch -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h1 class="text-3xl font-bold mb-4">Company Invitation</h1>

              <div class="alert alert-warning mb-4">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="stroke-current shrink-0 h-6 w-6"
                  fill="none"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                  />
                </svg>
                <div>
                  <p class="font-bold">Email mismatch</p>
                  <p class="text-sm">
                    This invitation was sent to <strong>{@invitation.invited_email}</strong>, but
                    you're logged in with a different email address.
                  </p>
                </div>
              </div>

              <.render_invitation_details invitation={@invitation} />

              <div class="card-actions justify-center mt-6">
                <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost">
                  Log out and use correct account
                </.link>
                <.link navigate={~p"/companies"} class="btn btn-primary">
                  Go to Companies
                </.link>
              </div>
            </div>
          </div>

        <% :can_accept -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h1 class="text-3xl font-bold mb-4">Company Invitation</h1>

              <div class="alert alert-success mb-4">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="stroke-current shrink-0 h-6 w-6"
                  fill="none"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                  />
                </svg>
                <span>You can accept this invitation!</span>
              </div>

              <.render_invitation_details invitation={@invitation} />

              <div class="card-actions justify-center mt-6">
                <.link navigate={~p"/companies"} class="btn btn-ghost">
                  Cancel
                </.link>
                <button type="button" phx-click="accept" class="btn btn-primary">
                  Accept Invitation
                </button>
              </div>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  defp render_invitation_details(assigns) do
    ~H"""
    <div class="bg-base-200 rounded-lg p-4">
      <h2 class="text-xl font-semibold mb-2">{@invitation.company.name}</h2>

      <p class="text-sm opacity-70 mb-2">
        Invited by {@invitation.invited_by && @invitation.invited_by.email || "Unknown"}
      </p>

      <div class="flex flex-wrap gap-2 mb-2">
        <div class="badge badge-primary">Role: {String.capitalize(@invitation.role)}</div>
        <div class="badge badge-outline">
          Expires: {Calendar.strftime(@invitation.expires_at, "%B %d, %Y")}
        </div>
      </div>

      <%= if @invitation.company.description do %>
        <p class="mt-2 text-sm">{@invitation.company.description}</p>
      <% end %>
    </div>
    """
  end
end
