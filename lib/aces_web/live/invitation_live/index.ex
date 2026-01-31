defmodule AcesWeb.InvitationLive.Index do
  @moduledoc """
  LiveView for displaying and managing pending company invitations for the current user.

  Users can accept or decline invitations directly from this page.
  """
  use AcesWeb, :live_view

  alias Aces.Companies

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    invitations = Companies.list_user_pending_invitations(user)

    {:ok,
     socket
     |> assign(:page_title, "My Invitations")
     |> assign(:invitations, invitations)}
  end

  @impl true
  def handle_event("accept", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    invitation = Companies.get_invitation!(id)

    case Companies.accept_invitation(invitation, user) do
      {:ok, _membership} ->
        invitations = Companies.list_user_pending_invitations(user)

        {:noreply,
         socket
         |> put_flash(:info, "You have joined #{invitation.company.name}!")
         |> assign(:invitations, invitations)}

      {:error, :email_mismatch} ->
        {:noreply, put_flash(socket, :error, "This invitation is for a different email address.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to accept invitation. Please try again.")}
    end
  end

  def handle_event("decline", %{"id" => id}, socket) do
    invitation = Companies.get_invitation!(id)

    case Companies.cancel_invitation(invitation) do
      {:ok, _} ->
        user = socket.assigns.current_scope.user
        invitations = Companies.list_user_pending_invitations(user)

        {:noreply,
         socket
         |> put_flash(:info, "Invitation declined.")
         |> assign(:invitations, invitations)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to decline invitation.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="mb-8">
        <h1 class="text-4xl font-bold mb-2">Company Invitations</h1>
        <p class="text-lg opacity-70">
          Review and accept invitations to join mercenary companies.
        </p>
      </div>

      <%= if @invitations == [] do %>
        <div class="alert alert-info">
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
          <span>You don't have any pending invitations.</span>
        </div>
      <% else %>
        <div class="grid gap-4">
          <%= for invitation <- @invitations do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">{invitation.company.name}</h2>

                <p class="text-sm opacity-70">
                  Invited by {invitation.invited_by && invitation.invited_by.email || "Unknown"}
                  on {Calendar.strftime(invitation.inserted_at, "%B %d, %Y")}
                </p>

                <div class="flex flex-wrap gap-2 mt-2">
                  <div class="badge badge-primary">Role: {String.capitalize(invitation.role)}</div>
                  <div class="badge badge-outline">
                    Expires: {Calendar.strftime(invitation.expires_at, "%B %d, %Y")}
                  </div>
                </div>

                <%= if invitation.company.description do %>
                  <p class="mt-2">{invitation.company.description}</p>
                <% end %>

                <div class="card-actions justify-end mt-4">
                  <button
                    type="button"
                    phx-click="decline"
                    phx-value-id={invitation.id}
                    data-confirm="Are you sure you want to decline this invitation?"
                    class="btn btn-ghost"
                  >
                    Decline
                  </button>
                  <button
                    type="button"
                    phx-click="accept"
                    phx-value-id={invitation.id}
                    class="btn btn-primary"
                  >
                    Accept Invitation
                  </button>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

      <div class="mt-8">
        <.link navigate={~p"/companies"} class="btn btn-ghost">
          Back to Companies
        </.link>
      </div>
    </div>
    """
  end
end
