defmodule AcesWeb.InvitationLive.Index do
  @moduledoc """
  LiveView for displaying and managing company invitations for the current user.

  Shows both pending invitations (with accept/decline actions) and
  invitation history (accepted, declined, expired).
  """
  use AcesWeb, :live_view

  alias Aces.Companies

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    all_invitations = Companies.list_user_all_invitations(user)

    {pending, history} = split_invitations(all_invitations)

    {:ok,
     socket
     |> assign(:page_title, "My Invitations")
     |> assign(:pending_invitations, pending)
     |> assign(:invitation_history, history)}
  end

  defp split_invitations(invitations) do
    now = DateTime.utc_now()

    Enum.split_with(invitations, fn inv ->
      inv.status == "pending" && DateTime.compare(inv.expires_at, now) == :gt
    end)
  end

  @impl true
  def handle_event("accept", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    invitation = Companies.get_invitation!(id)

    case Companies.accept_invitation(invitation, user) do
      {:ok, _membership} ->
        all_invitations = Companies.list_user_all_invitations(user)
        {pending, history} = split_invitations(all_invitations)

        {:noreply,
         socket
         |> put_flash(:info, "You have joined #{invitation.company.name}!")
         |> assign(:pending_invitations, pending)
         |> assign(:invitation_history, history)}

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
        all_invitations = Companies.list_user_all_invitations(user)
        {pending, history} = split_invitations(all_invitations)

        {:noreply,
         socket
         |> put_flash(:info, "Invitation declined.")
         |> assign(:pending_invitations, pending)
         |> assign(:invitation_history, history)}

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
          Review invitations to join mercenary companies.
        </p>
      </div>

      <!-- Pending Invitations Section -->
      <div class="mb-8">
        <h2 class="text-2xl font-bold mb-4">Pending Invitations</h2>

        <%= if @pending_invitations == [] do %>
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
            <%= for invitation <- @pending_invitations do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body">
                  <h3 class="card-title">{invitation.company.name}</h3>

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
      </div>

      <!-- Invitation History Section -->
      <%= if @invitation_history != [] do %>
        <div class="divider"></div>

        <div class="mb-8">
          <h2 class="text-2xl font-bold mb-4">Invitation History</h2>

          <div class="overflow-x-auto">
            <table class="table table-zebra w-full">
              <thead>
                <tr>
                  <th>Company</th>
                  <th>Role</th>
                  <th>Invited By</th>
                  <th>Date</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                <%= for invitation <- @invitation_history do %>
                  <tr>
                    <td>
                      <div class="font-semibold">{invitation.company.name}</div>
                      <%= if invitation.company.description do %>
                        <div class="text-sm opacity-70 truncate max-w-xs">
                          {invitation.company.description}
                        </div>
                      <% end %>
                    </td>
                    <td>{String.capitalize(invitation.role)}</td>
                    <td class="text-sm">
                      {invitation.invited_by && invitation.invited_by.email || "Unknown"}
                    </td>
                    <td class="text-sm">
                      {Calendar.strftime(invitation.inserted_at, "%b %d, %Y")}
                    </td>
                    <td>
                      <.status_badge invitation={invitation} />
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
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

  defp status_badge(assigns) do
    now = DateTime.utc_now()

    {status, class} =
      cond do
        assigns.invitation.status == "accepted" ->
          {"Accepted", "badge-success"}

        assigns.invitation.status == "cancelled" ->
          {"Declined", "badge-warning"}

        assigns.invitation.status == "pending" &&
            DateTime.compare(assigns.invitation.expires_at, now) != :gt ->
          {"Expired", "badge-error"}

        true ->
          {String.capitalize(assigns.invitation.status), "badge-ghost"}
      end

    assigns = assign(assigns, :status, status)
    assigns = assign(assigns, :class, class)

    ~H"""
    <div class={"badge #{@class}"}>{@status}</div>
    """
  end
end
