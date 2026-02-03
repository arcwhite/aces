defmodule AcesWeb.InvitationLive.Index do
  @moduledoc """
  LiveView for displaying and managing company invitations for the current user.

  Shows:
  - Pending invitations received (with accept/decline actions)
  - Invitation history received (accepted, declined, expired)
  - Invitations sent to others (with status)
  """
  use AcesWeb, :live_view

  alias Aces.Companies

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, "My Invitations")
     |> load_invitations(user)}
  end

  defp load_invitations(socket, user) do
    all_received = Companies.list_user_all_invitations(user)
    {pending, history} = split_invitations(all_received)
    sent = Companies.list_user_sent_invitations(user)

    socket
    |> assign(:pending_invitations, pending)
    |> assign(:invitation_history, history)
    |> assign(:sent_invitations, sent)
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
        {:noreply,
         socket
         |> put_flash(:info, "You have joined #{invitation.company.name}!")
         |> load_invitations(user)}

      {:error, :email_mismatch} ->
        {:noreply, put_flash(socket, :error, "This invitation is for a different email address.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to accept invitation. Please try again.")}
    end
  end

  def handle_event("decline", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    invitation = Companies.get_invitation!(id)

    case Companies.cancel_invitation(invitation) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation declined.")
         |> load_invitations(user)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to decline invitation.")}
    end
  end

  def handle_event("cancel_sent", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    invitation = Companies.get_invitation!(id)

    case Companies.cancel_invitation(invitation) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation cancelled.")
         |> load_invitations(user)}

      {:error, :not_pending} ->
        {:noreply, put_flash(socket, :error, "Can only cancel pending invitations.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel invitation.")}
    end
  end

  def handle_event("resend_invitation", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    invitation = Companies.get_invitation!(id)

    case Companies.resend_invitation(invitation) do
      {:ok, {encoded_token, updated_invitation}} ->
        # Send the invitation email with new token
        url = AcesWeb.Endpoint.url() <> ~p"/invitations/#{encoded_token}"
        Aces.Accounts.UserNotifier.deliver_company_invitation(
          updated_invitation.invited_email,
          updated_invitation,
          url
        )

        {:noreply,
         socket
         |> put_flash(:info, "Invitation resent to #{updated_invitation.invited_email}.")
         |> load_invitations(user)}

      {:error, :not_pending} ->
        {:noreply, put_flash(socket, :error, "Can only resend pending invitations.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to resend invitation.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="mb-8">
        <h1 class="text-4xl font-bold mb-2">Invitations</h1>
        <p class="text-lg opacity-70">
          Manage invitations to join mercenary companies.
        </p>
      </div>

      <!-- Pending Invitations Received Section -->
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

      <!-- Invitations Sent Section -->
      <div class="divider"></div>

      <div class="mb-8">
        <h2 class="text-2xl font-bold mb-4">Invitations Sent</h2>

        <%= if @sent_invitations == [] do %>
          <div class="text-sm opacity-70">
            You haven't sent any invitations yet.
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-zebra w-full">
              <thead>
                <tr>
                  <th>Invited Email</th>
                  <th>Company</th>
                  <th>Role</th>
                  <th>Sent</th>
                  <th>Status</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for invitation <- @sent_invitations do %>
                  <tr>
                    <td class="font-semibold">{invitation.invited_email}</td>
                    <td>{invitation.company.name}</td>
                    <td>{String.capitalize(invitation.role)}</td>
                    <td class="text-sm">
                      {Calendar.strftime(invitation.inserted_at, "%b %d, %Y")}
                    </td>
                    <td>
                      <.status_badge invitation={invitation} />
                    </td>
                    <td>
                      <%= if invitation.status == "pending" do %>
                        <div class="flex gap-1">
                          <button
                            type="button"
                            phx-click="resend_invitation"
                            phx-value-id={invitation.id}
                            class="btn btn-ghost btn-xs"
                          >
                            Resend
                          </button>
                          <%= if DateTime.compare(invitation.expires_at, DateTime.utc_now()) == :gt do %>
                            <button
                              type="button"
                              phx-click="cancel_sent"
                              phx-value-id={invitation.id}
                              data-confirm="Cancel this invitation?"
                              class="btn btn-ghost btn-xs"
                            >
                              Cancel
                            </button>
                          <% end %>
                        </div>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>

      <!-- Invitation History Received Section -->
      <%= if @invitation_history != [] do %>
        <div class="divider"></div>

        <div class="mb-8">
          <h2 class="text-2xl font-bold mb-4">Received History</h2>

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

        assigns.invitation.status == "pending" ->
          {"Pending", "badge-info"}

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
