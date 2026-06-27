defmodule AcesWeb.CompanyLive.InviteModal do
  @moduledoc """
  LiveComponent for inviting users to join a company.
  """
  use AcesWeb, :live_component

  alias Aces.Companies
  alias Aces.Accounts.UserNotifier

  @impl true
  def render(assigns) do
    ~H"""
    <div id="invite-modal-root" phx-hook="ClipboardCopy">
      <.modal :if={@show} show={true} on_close="close" max_width="2xl" phx-target={@myself}>
        <:title>Invite Member</:title>

        <%= if @state == :success do %>
          <div class="space-y-4">
            <p>
              Invitation created for <span class="font-semibold">{@invited_email}</span>.
            </p>
            <div>
              <label class="label">
                <span class="label-text">Invitation link</span>
              </label>
              <code
                class="block w-full break-all bg-base-200 rounded p-2 text-sm"
                style="user-select: all;"
              >{@url}</code>
            </div>
            <div class="flex justify-end gap-2 pt-4">
              <button
                type="button"
                id="modal-copy-link"
                phx-click="copy_link"
                phx-target={@myself}
                class="btn btn-secondary"
              >
                Copy link
              </button>
              <button
                type="button"
                phx-click="done"
                phx-target={@myself}
                class="btn btn-primary"
              >
                Done
              </button>
            </div>
          </div>
        <% else %>
          <.form for={@form} phx-submit="send_invite" phx-target={@myself} class="space-y-4">
            <div class="form-control">
              <label class="label">
                <span class="label-text">Email Address</span>
              </label>
              <input
                type="email"
                name="email"
                value={@form[:email].value}
                placeholder="user@example.com"
                class="input input-bordered w-full"
                required
              />
              <%= if @form[:email].errors != [] do %>
                <label class="label">
                  <span class="label-text-alt text-error">
                    {Enum.map(@form[:email].errors, fn {msg, _} -> msg end) |> Enum.join(", ")}
                  </span>
                </label>
              <% end %>
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text">Role</span>
              </label>
              <select name="role" class="select select-bordered w-full">
                <option value="viewer">Viewer - Can view company and campaigns</option>
                <option value="editor">Editor - Can edit company, add units and pilots</option>
                <option value="owner">Owner - Full access including member management</option>
              </select>
            </div>

            <%= if @error do %>
              <div class="alert alert-error">
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
                    d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
                  />
                </svg>
                <span>{@error}</span>
              </div>
            <% end %>

            <div class="flex justify-end gap-2 pt-4">
              <button type="button" phx-click="close" phx-target={@myself} class="btn btn-ghost">
                Cancel
              </button>
              <button type="submit" class="btn btn-primary">
                Send Invitation
              </button>
            </div>
          </.form>
        <% end %>
      </.modal>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn -> to_form(%{"email" => "", "role" => "viewer"}) end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:state, fn -> :form end)
     |> assign_new(:url, fn -> nil end)
     |> assign_new(:invited_email, fn -> nil end)}
  end

  @impl true
  def handle_event("close", _params, socket) do
    send(self(), {__MODULE__, :close_modal})
    {:noreply, reset_to_form(socket)}
  end

  def handle_event("done", _params, socket) do
    send(self(), {__MODULE__, {:invitation_sent, socket.assigns.invited_email}})
    {:noreply, reset_to_form(socket)}
  end

  def handle_event("copy_link", _params, socket) do
    {:noreply,
     push_event(socket, "copy_to_clipboard", %{
       text: socket.assigns.url,
       button_id: "modal-copy-link"
     })}
  end

  def handle_event("send_invite", %{"email" => email, "role" => role}, socket) do
    company = socket.assigns.company
    user = socket.assigns.current_user

    case Companies.create_invitation(company, user, email, role) do
      {:ok, {encoded_token, invitation}} ->
        url = url(~p"/invitations/#{encoded_token}")

        invitation_with_preloads = Companies.get_invitation!(invitation.id)
        UserNotifier.deliver_company_invitation(email, invitation_with_preloads, url)

        {:noreply,
         socket
         |> assign(:state, :success)
         |> assign(:url, url)
         |> assign(:invited_email, email)
         |> assign(:error, nil)}

      {:error, :already_member} ->
        {:noreply, assign(socket, :error, "This user is already a member of this company.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        error =
          case changeset.errors[:invited_email] do
            {msg, _} -> msg
            _ -> "Failed to create invitation. Please try again."
          end

        {:noreply, assign(socket, :error, error)}
    end
  end

  defp reset_to_form(socket) do
    socket
    |> assign(:state, :form)
    |> assign(:error, nil)
    |> assign(:url, nil)
    |> assign(:invited_email, nil)
    |> assign(:form, to_form(%{"email" => "", "role" => "viewer"}))
  end
end
