defmodule AcesWeb.CompanyLive.Show do
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns, ChangesetHelpers}
  alias Aces.Companies.Authorization
  alias Aces.Companies.Units, as: CompanyUnits
  alias Aces.PubSub.Broadcasts

  on_mount {AcesWeb.UserAuthLive, :default}

  # Tab definitions - hoisted here for discoverability
  @tabs [
    {"Overview", :overview},
    {"Pilots", :pilots},
    {"Units", :units},
    {"Settings", :settings}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    company = Companies.get_company_with_stats!(id)
    user = socket.assigns.current_scope.user

    unless Authorization.can?(:view_company, user, company) do
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view this company")
       |> redirect(to: ~p"/companies")}
    else
      if company.status == "draft" do
        {:ok,
         socket
         |> put_flash(:info, "This company is still in draft status. Complete setup to activate it.")
         |> redirect(to: ~p"/companies/#{company}/draft")}
      else
        # Subscribe to company updates for real-time sync
        if connected?(socket), do: Broadcasts.subscribe_company(company.id)

        active_campaign = Campaigns.get_active_campaign(company)
        can_manage = Authorization.can?(:manage_members, user, company)
        pending_invitations = if can_manage, do: Companies.list_pending_invitations(company), else: []
        members = Companies.list_company_members(company)

        {:ok,
         socket
         |> assign(:company, company)
         |> assign(:active_campaign, active_campaign)
         |> assign(:page_title, company.name)
         |> assign(:tabs, @tabs)
         |> assign(:active_tab, :overview)
         |> assign(:show_unit_search, false)
         |> assign(:show_unit_edit, false)
         |> assign(:show_invite_modal, false)
         |> assign(:pending_invitations, pending_invitations)
         |> assign(:members, members)
         |> assign(:current_user_id, user.id)
         |> assign(:can_manage_members, can_manage)
         |> assign(:editing_unit, nil)
         |> assign(:editing_pilot, nil)
         |> assign(:show_pilot_edit, false)}
      end
    end
  end

  defp reload_members(socket) do
    company = socket.assigns.company
    members = Companies.list_company_members(company)
    assign(socket, :members, members)
  end

  defp reload_invitations(socket) do
    company = socket.assigns.company

    if socket.assigns.can_manage_members do
      pending_invitations = Companies.list_pending_invitations(company)
      assign(socket, :pending_invitations, pending_invitations)
    else
      socket
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_modal_state(socket, params)}
  end

  # Apply modal state from URL params - enables modal state to survive reconnection
  defp apply_modal_state(socket, %{"modal" => "invite"}) do
    socket
    |> close_all_modals()
    |> assign(:show_invite_modal, true)
  end

  defp apply_modal_state(socket, %{"modal" => "unit_search"}) do
    socket
    |> close_all_modals()
    |> assign(:show_unit_search, true)
  end

  defp apply_modal_state(socket, %{"modal" => "unit_edit", "unit_id" => unit_id_str}) do
    case find_unit(socket, unit_id_str) do
      nil ->
        socket
        |> close_all_modals()
        |> put_flash(:error, "Unit not found")

      unit ->
        socket
        |> close_all_modals()
        |> assign(:show_unit_edit, true)
        |> assign(:editing_unit, unit)
    end
  end

  defp apply_modal_state(socket, %{"modal" => "pilot_edit", "pilot_id" => pilot_id_str}) do
    case find_pilot(socket, pilot_id_str) do
      nil ->
        socket
        |> close_all_modals()
        |> put_flash(:error, "Pilot not found")

      pilot ->
        socket
        |> close_all_modals()
        |> assign(:show_pilot_edit, true)
        |> assign(:editing_pilot, pilot)
    end
  end

  # Default case: close all modals
  defp apply_modal_state(socket, _params) do
    close_all_modals(socket)
  end

  defp close_all_modals(socket) do
    socket
    |> assign(:show_invite_modal, false)
    |> assign(:show_unit_search, false)
    |> assign(:show_unit_edit, false)
    |> assign(:show_pilot_edit, false)
    |> assign(:editing_unit, nil)
    |> assign(:editing_pilot, nil)
  end

  defp find_unit(socket, unit_id_str) do
    case Integer.parse(unit_id_str) do
      {unit_id, ""} ->
        Enum.find(socket.assigns.company.company_units, &(&1.id == unit_id))

      _ ->
        nil
    end
  end

  defp find_pilot(socket, pilot_id_str) do
    case Integer.parse(pilot_id_str) do
      {pilot_id, ""} ->
        Enum.find(socket.assigns.company.pilots, &(&1.id == pilot_id))

      _ ->
        nil
    end
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  def handle_event("add_unit", _params, socket) do
    company = socket.assigns.company

    if company.status == "active" do
      {:noreply,
       socket
       |> put_flash(:error, "Cannot add units with PV to finalized companies. Units must be purchased with SP.")}
    else
      {:noreply, push_patch(socket, to: ~p"/companies/#{company}?modal=unit_search")}
    end
  end

  def handle_event("edit_unit", %{"unit_id" => unit_id_str}, socket) do
    company = socket.assigns.company
    {:noreply, push_patch(socket, to: ~p"/companies/#{company}?modal=unit_edit&unit_id=#{unit_id_str}")}
  end

  def handle_event("close_unit_edit", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/companies/#{socket.assigns.company}")}
  end

  def handle_event("edit_pilot", %{"pilot_id" => pilot_id_str}, socket) do
    company = socket.assigns.company
    {:noreply, push_patch(socket, to: ~p"/companies/#{company}?modal=pilot_edit&pilot_id=#{pilot_id_str}")}
  end

  def handle_event("close_pilot_edit", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/companies/#{socket.assigns.company}")}
  end

  def handle_event("invite_member", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/companies/#{socket.assigns.company}?modal=invite")}
  end

  def handle_event("cancel_invitation", %{"id" => id}, socket) do
    invitation = Companies.get_invitation!(id)

    case Companies.cancel_invitation(invitation) do
      {:ok, _} ->
        company = socket.assigns.company
        pending_invitations = Companies.list_pending_invitations(company)

        {:noreply,
         socket
         |> put_flash(:info, "Invitation cancelled.")
         |> assign(:pending_invitations, pending_invitations)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel invitation.")}
    end
  end

  def handle_event("resend_invitation", %{"id" => id}, socket) do
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

        company = socket.assigns.company
        pending_invitations = Companies.list_pending_invitations(company)

        {:noreply,
         socket
         |> put_flash(:info, "Invitation resent to #{updated_invitation.invited_email}.")
         |> assign(:pending_invitations, pending_invitations)}

      {:error, :not_pending} ->
        {:noreply, put_flash(socket, :error, "Can only resend pending invitations.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to resend invitation.")}
    end
  end

  def handle_event("change_member_role", %{"membership_id" => id, "role" => role}, socket) do
    user = socket.assigns.current_scope.user
    company = socket.assigns.company

    if Authorization.can?(:manage_members, user, company) do
      membership = Aces.Repo.get!(Aces.Companies.CompanyMembership, id)

      case Companies.update_member_role(membership, role) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Role updated successfully.")
           |> reload_members()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update role.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to manage members.")}
    end
  end

  def handle_event("remove_member", %{"membership_id" => id}, socket) do
    user = socket.assigns.current_scope.user
    company = socket.assigns.company

    if Authorization.can?(:manage_members, user, company) do
      membership = Aces.Repo.preload(Aces.Repo.get!(Aces.Companies.CompanyMembership, id), :user)

      # Owners cannot remove other owners
      if membership.role == "owner" do
        {:noreply, put_flash(socket, :error, "Cannot remove an owner from the company.")}
      else
        case Companies.remove_member(membership) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{membership.user.email} has been removed from the company.")
             |> reload_members()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to remove member.")}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to manage members.")}
    end
  end

  @impl true
  def handle_event("delete_company", %{"id" => id}, socket) do
    company = Companies.get_company!(id)
    user = socket.assigns.current_scope.user

    if Authorization.can?(:delete_company, user, company) do
      {:ok, _} = Companies.delete_company(company)

      {:noreply,
       socket
       |> put_flash(:info, "Company deleted successfully")
       |> redirect(to: ~p"/companies")}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to delete this company")}
    end
  end

  @impl true
  def handle_info({AcesWeb.CompanyLive.UnitEditComponent, {:saved, _unit}}, socket) do
    updated_company = Companies.get_company_with_stats!(socket.assigns.company.id)

    {:noreply,
     socket
     |> assign(:company, updated_company)
     |> push_patch(to: ~p"/companies/#{socket.assigns.company}")}
  end

  def handle_info({AcesWeb.CompanyLive.PilotFormComponent, {:saved, _pilot}}, socket) do
    updated_company = Companies.get_company_with_stats!(socket.assigns.company.id)

    {:noreply,
     socket
     |> assign(:company, updated_company)
     |> push_patch(to: ~p"/companies/#{socket.assigns.company}")}
  end

  def handle_info({AcesWeb.Components.UnitSearchModal, :close_modal}, socket) do
    {:noreply, push_patch(socket, to: ~p"/companies/#{socket.assigns.company}")}
  end

  def handle_info({AcesWeb.CompanyLive.InviteModal, :close_modal}, socket) do
    {:noreply, push_patch(socket, to: ~p"/companies/#{socket.assigns.company}")}
  end

  def handle_info({AcesWeb.CompanyLive.InviteModal, {:invitation_sent, email}}, socket) do
    company = socket.assigns.company
    pending_invitations = Companies.list_pending_invitations(company)

    {:noreply,
     socket
     |> put_flash(:info, "Invitation sent to #{email}!")
     |> assign(:pending_invitations, pending_invitations)
     |> push_patch(to: ~p"/companies/#{company}")}
  end

  def handle_info({AcesWeb.Components.UnitSearchModal, {:unit_selected, mul_id}}, socket) do
    company = socket.assigns.company
    user = socket.assigns.current_scope.user

    if Authorization.can?(:edit_company, user, company) do
      case CompanyUnits.purchase_unit_for_company(company, mul_id) do
        {:ok, _company_unit} ->
          updated_company = Companies.get_company_with_stats!(company.id)

          {:noreply,
           socket
           |> assign(:company, updated_company)
           |> put_flash(:info, "Unit successfully added to roster!")
           |> push_patch(to: ~p"/companies/#{company}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          error_message = ChangesetHelpers.format_errors(changeset)

          {:noreply,
           socket
           |> put_flash(:error, "Failed to add unit: #{error_message}")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to add units to this company")}
    end
  end

  # Handle PubSub company updates for real-time sync across tabs/users
  def handle_info({:company_updated, %{event: event, payload: _payload}}, socket) do
    company = socket.assigns.company
    user = socket.assigns.current_scope.user

    # Re-verify authorization - user might have been removed
    unless Authorization.can?(:view_company, user, company) do
      {:noreply,
       socket
       |> put_flash(:error, "You no longer have access to this company")
       |> redirect(to: ~p"/companies")}
    else
      # Reload data based on event type
      socket =
        case event do
          event when event in [:member_added, :member_removed, :member_role_changed] ->
            socket
            |> reload_members()
            |> reload_invitations()

          event when event in [:invitation_created, :invitation_cancelled] ->
            reload_invitations(socket)

          _ ->
            socket
        end

      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="mb-6">
        <div class="flex items-center gap-4 mb-4">
          <.link navigate={~p"/companies"} class="btn btn-ghost btn-sm">
            &larr; Back to Companies
          </.link>
        </div>

        <h1 class="text-4xl font-bold mb-2">{@company.name}</h1>
        <%= if @company.description do %>
          <p class="text-lg opacity-70">{@company.description}</p>
        <% end %>
      </div>

      <!-- Tab Navigation -->
      <.tab_navigation tabs={@tabs} active_tab={@active_tab} />

      <!-- Tab Content -->
      <.tab_content
        tabs={@tabs}
        active_tab={@active_tab}
        company={@company}
        active_campaign={@active_campaign}
        members={@members}
        pending_invitations={@pending_invitations}
        current_user_id={@current_user_id}
        can_manage_members={@can_manage_members}
      />

      <!-- Unit Search Modal -->
      <.live_component
        module={AcesWeb.Components.UnitSearchModal}
        id="unit-search"
        show={@show_unit_search}
        mode={:pv_budget}
        budget={@company.stats.pv_remaining}
        error={nil}
      />

      <!-- Unit Edit Modal -->
      <.modal show={@show_unit_edit && @editing_unit != nil} on_close="close_unit_edit" max_width="2xl">
        <:title>Edit Unit</:title>
        <%= if @editing_unit do %>
          <.live_component
            module={AcesWeb.CompanyLive.UnitEditComponent}
            id={:edit_unit}
            action={:edit_unit}
            unit={@editing_unit}
            company={@company}
            patch={~p"/companies/#{@company}"}
          />
        <% end %>
      </.modal>

      <!-- Pilot Edit Modal -->
      <.modal show={@show_pilot_edit && @editing_pilot != nil} on_close="close_pilot_edit" max_width="4xl">
        <:title>Edit Pilot</:title>
        <%= if @editing_pilot do %>
          <.live_component
            module={AcesWeb.CompanyLive.PilotFormComponent}
            id={:edit_pilot}
            action={:edit}
            pilot={@editing_pilot}
            company={@company}
            title="Edit Pilot"
            patch={~p"/companies/#{@company}"}
          />
        <% end %>
      </.modal>

      <!-- Invite Member Modal -->
      <.live_component
        module={AcesWeb.CompanyLive.InviteModal}
        id="invite-modal"
        show={@show_invite_modal}
        company={@company}
        current_user={@current_scope.user}
      />
    </div>
    """
  end

  # Tab content router - tabs defined in @tabs module attribute at top of file
  defp tab_content(assigns) do
    case assigns.active_tab do
      :overview -> overview_tab(assigns)
      :pilots -> pilots_tab(assigns)
      :units -> units_tab(assigns)
      :settings -> settings_tab(assigns)
    end
  end

  # Overview Tab - company stats and active campaign
  defp overview_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Company Stats Grid -->
      <div class="grid grid-cols-2 gap-3 md:gap-6 lg:grid-cols-5">
        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4">
          <div class="stat-title text-xs md:text-sm">Units</div>
          <div class="stat-value text-xl md:text-3xl text-primary">{@company.stats.unit_count}</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4">
          <div class="stat-title text-xs md:text-sm">Pilots</div>
          <div class="stat-value text-xl md:text-3xl text-info">{@company.stats.pilot_count}</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4">
          <div class="stat-title text-xs md:text-sm">PV Budget</div>
          <div class="stat-value text-xl md:text-3xl text-accent">
            <span class="whitespace-nowrap">{@company.stats.pv_remaining}/{@company.stats.pv_budget}</span>
          </div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4">
          <div class="stat-title text-xs md:text-sm">Warchest</div>
          <div class="stat-value text-xl md:text-3xl text-secondary">{@company.stats.warchest_balance}</div>
          <div class="stat-desc text-xs hidden md:block">SP available</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4 col-span-2 lg:col-span-1">
          <div class="stat-title text-xs md:text-sm">Last Updated</div>
          <div class="stat-value text-sm md:text-lg">
            {Calendar.strftime(@company.stats.last_modified, "%b %d, %Y")}
          </div>
        </div>
      </div>

      <!-- Active Campaign Section -->
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 mb-4">
            <h2 class="card-title text-2xl">Active Campaign</h2>
            <%= if @active_campaign do %>
              <.link
                navigate={~p"/companies/#{@company.id}/campaigns/#{@active_campaign.id}"}
                class="btn btn-primary"
              >
                View Campaign Details
              </.link>
            <% else %>
              <%= if @company.status == "active" do %>
                <.link
                  navigate={~p"/companies/#{@company.id}/campaigns/new"}
                  class="btn btn-primary"
                >
                  Start New Campaign
                </.link>
              <% end %>
            <% end %>
          </div>

          <%= if @active_campaign do %>
            <div>
              <h3 class="text-xl font-semibold mb-2">{@active_campaign.name}</h3>
              <%= if @active_campaign.description do %>
                <p class="opacity-70 mb-4">{@active_campaign.description}</p>
              <% end %>

              <div class="grid gap-4 md:grid-cols-4">
                <div class="stat bg-base-200 rounded-lg">
                  <div class="stat-title text-xs">Difficulty</div>
                  <div class="stat-value text-lg">{String.capitalize(@active_campaign.difficulty_level)}</div>
                </div>

                <div class="stat bg-base-200 rounded-lg">
                  <div class="stat-title text-xs">Campaign Warchest</div>
                  <div class="stat-value text-lg text-secondary">{@active_campaign.warchest_balance} SP</div>
                </div>

                <div class="stat bg-base-200 rounded-lg">
                  <div class="stat-title text-xs">Sorties</div>
                  <div class="stat-value text-lg text-info">{length(@active_campaign.sorties)}</div>
                </div>

                <div class="stat bg-base-200 rounded-lg">
                  <div class="stat-title text-xs">Status</div>
                  <div class="stat-value text-lg">
                    <div class="badge badge-success">{String.capitalize(@active_campaign.status)}</div>
                  </div>
                </div>
              </div>

              <%= if @active_campaign.keywords && length(@active_campaign.keywords) > 0 do %>
                <div class="flex gap-2 flex-wrap mt-4">
                  <%= for keyword <- @active_campaign.keywords do %>
                    <div class="badge badge-outline badge-sm">{keyword}</div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="alert alert-info">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
              </svg>
              <div>
                <p class="font-semibold">No active campaign</p>
                <p class="text-sm">
                  <%= if @company.status == "active" do %>
                    Start a new campaign to deploy your company on missions, hire new pilots, and purchase additional units.
                  <% else %>
                    Complete company setup to start campaigns.
                  <% end %>
                </p>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Campaign Actions Info Box -->
      <div class="alert alert-warning">
        <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
        </svg>
        <div>
          <h3 class="font-bold">Unit Purchases &amp; Pilot Hiring</h3>
          <p class="text-sm">
            <%= if @active_campaign do %>
              Purchase units and hire pilots from the
              <.link navigate={~p"/companies/#{@company.id}/campaigns/#{@active_campaign.id}"} class="link link-primary">
                campaign page
              </.link>
              using your campaign warchest ({@active_campaign.warchest_balance} SP available).
            <% else %>
              Your company is currently in transit. Start a campaign to purchase units and hire pilots using SP from your warchest.
            <% end %>
          </p>
        </div>
      </div>
    </div>
    """
  end

  # Pilots Tab
  defp pilots_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 mb-4">
        <div>
          <h2 class="text-2xl font-bold">Pilot Roster</h2>
          <p class="text-sm opacity-70">{length(@company.pilots)} pilots in your company</p>
        </div>

        <%= if @active_campaign do %>
          <.link
            navigate={~p"/companies/#{@company.id}/campaigns/#{@active_campaign.id}"}
            class="btn btn-primary btn-sm"
          >
            Hire Pilots (Campaign)
          </.link>
        <% end %>
      </div>

      <%= if @company.pilots == [] do %>
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
          <div>
            <p class="font-semibold">No pilots yet</p>
            <p class="text-sm">
              <%= if @active_campaign do %>
                Hire pilots from the campaign page using SP from your warchest.
              <% else %>
                Start a campaign to hire pilots for your company.
              <% end %>
            </p>
          </div>
        </div>
      <% else %>
        <.pilot_cards pilots={@company.pilots} show_actions={true} />
      <% end %>
    </div>
    """
  end

  # Units Tab
  defp units_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 mb-4">
        <div>
          <h2 class="text-2xl font-bold">Unit Roster</h2>
          <p class="text-sm opacity-70">{length(@company.company_units)} units in your company</p>
        </div>

        <%= if @active_campaign do %>
          <.link
            navigate={~p"/companies/#{@company.id}/campaigns/#{@active_campaign.id}"}
            class="btn btn-primary btn-sm"
          >
            Purchase Units (Campaign)
          </.link>
        <% end %>
      </div>

      <%= if @company.company_units == [] do %>
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
          <div>
            <p class="font-semibold">No units yet</p>
            <p class="text-sm">
              <%= if @active_campaign do %>
                Purchase units from the campaign page using SP from your warchest.
              <% else %>
                Start a campaign to purchase units for your company.
              <% end %>
            </p>
          </div>
        </div>
      <% else %>
        <div class="overflow-x-auto">
          <table class="table table-zebra w-full">
            <thead>
              <tr>
                <th>Unit</th>
                <th class="hidden md:table-cell">Custom Name</th>
                <th>Status</th>
                <th class="hidden sm:table-cell">Pilot</th>
                <th class="hidden md:table-cell">Skill</th>
                <th class="hidden lg:table-cell">Armor/Structure</th>
                <th class="hidden lg:table-cell">Damage (S/M/L)</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for unit <- @company.company_units do %>
                <tr>
                  <td>
                    <%= if unit.master_unit do %>
                      <!-- Mobile: show custom name if set, otherwise unit name -->
                      <div class="font-semibold">
                        <span class="md:hidden">
                          {unit.custom_name || Aces.Units.MasterUnit.display_name(unit.master_unit)}
                        </span>
                        <span class="hidden md:inline">
                          {Aces.Units.MasterUnit.display_name(unit.master_unit)}
                        </span>
                      </div>
                      <div class="flex flex-wrap gap-1 mt-1">
                        <div class="badge badge-outline badge-xs md:badge-sm">
                          {String.replace(unit.master_unit.unit_type, "_", " ") |> String.capitalize()}
                        </div>
                        <%= if unit.master_unit.tonnage do %>
                          <div class="badge badge-neutral badge-xs md:badge-sm">{unit.master_unit.tonnage}t</div>
                        <% end %>
                        <%= if unit.master_unit.point_value do %>
                          <div class="badge badge-accent badge-xs md:badge-sm whitespace-nowrap">{unit.master_unit.point_value} PV</div>
                        <% end %>
                      </div>
                    <% else %>
                      <div class="font-semibold text-gray-500">Unknown Unit</div>
                    <% end %>
                  </td>
                  <td class="hidden md:table-cell">{unit.custom_name || "-"}</td>
                  <td>
                    <div class={[
                      "badge badge-xs md:badge-md",
                      unit.status == "operational" && "badge-success",
                      unit.status == "damaged" && "badge-warning",
                      unit.status == "destroyed" && "badge-error"
                    ]}>
                      {unit.status}
                    </div>
                  </td>
                  <td class="hidden sm:table-cell">
                    <%= if unit.pilot do %>
                      <span class="text-sm">{unit.pilot.name}</span>
                    <% else %>
                      <span class="text-gray-500 text-sm">Unassigned</span>
                    <% end %>
                  </td>
                  <td class="hidden md:table-cell">
                    <div class="badge badge-outline">
                      Skill {Aces.Companies.CompanyUnit.effective_skill_level(unit)}
                    </div>
                  </td>
                  <td class="hidden lg:table-cell">
                    <%= if unit.master_unit && unit.master_unit.bf_armor && unit.master_unit.bf_structure do %>
                      <span class="text-sm">{unit.master_unit.bf_armor}/{unit.master_unit.bf_structure}</span>
                    <% else %>
                      -
                    <% end %>
                  </td>
                  <td class="hidden lg:table-cell">
                    <%= if unit.master_unit && unit.master_unit.bf_damage_short && unit.master_unit.bf_damage_medium && unit.master_unit.bf_damage_long do %>
                      <span class="text-xs font-mono">{unit.master_unit.bf_damage_short}/{unit.master_unit.bf_damage_medium}/{unit.master_unit.bf_damage_long}</span>
                    <% else %>
                      -
                    <% end %>
                  </td>
                  <td>
                    <button
                      class="btn btn-ghost btn-sm md:btn-xs"
                      phx-click="edit_unit"
                      phx-value-unit_id={unit.id}
                    >
                      Edit
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  # Settings Tab
  defp settings_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <h2 class="text-2xl font-bold">Company Settings</h2>

      <!-- Team Members Section -->
      <div class="card bg-base-200 shadow-xl">
        <div class="card-body">
          <div class="flex justify-between items-center">
            <h3 class="card-title">Team Members</h3>
            <%= if @can_manage_members do %>
              <button type="button" phx-click="invite_member" class="btn btn-primary btn-sm">
                Invite Member
              </button>
            <% end %>
          </div>

          <!-- Current Members List -->
          <div class="overflow-x-auto mt-4">
            <table class="table w-full">
              <thead>
                <tr>
                  <th>Member</th>
                  <th>Role</th>
                  <th>Joined</th>
                  <%= if @can_manage_members do %>
                    <th>Actions</th>
                  <% end %>
                </tr>
              </thead>
              <tbody>
                <%= for membership <- @members do %>
                  <tr class={if membership.user_id == @current_user_id, do: "bg-base-300"}>
                    <td>
                      <div class="flex items-center gap-2">
                        <span class="font-semibold">{membership.user.email}</span>
                        <%= if membership.user_id == @current_user_id do %>
                          <span class="badge badge-sm badge-ghost">You</span>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <%= if @can_manage_members && membership.user_id != @current_user_id do %>
                        <select
                          class="select select-bordered select-sm w-full max-w-xs"
                          phx-change="change_member_role"
                          phx-value-membership_id={membership.id}
                          name="role"
                        >
                          <option value="viewer" selected={membership.role == "viewer"}>Viewer</option>
                          <option value="editor" selected={membership.role == "editor"}>Editor</option>
                          <option value="owner" selected={membership.role == "owner"}>Owner</option>
                        </select>
                      <% else %>
                        <div class={[
                          "badge",
                          membership.role == "owner" && "badge-primary",
                          membership.role == "editor" && "badge-secondary",
                          membership.role == "viewer" && "badge-ghost"
                        ]}>
                          {String.capitalize(membership.role)}
                        </div>
                      <% end %>
                    </td>
                    <td class="text-sm opacity-70">
                      {Calendar.strftime(membership.inserted_at, "%b %d, %Y")}
                    </td>
                    <%= if @can_manage_members do %>
                      <td>
                        <%= if membership.user_id != @current_user_id && membership.role != "owner" do %>
                          <button
                            type="button"
                            phx-click="remove_member"
                            phx-value-membership_id={membership.id}
                            data-confirm={"Remove #{membership.user.email} from this company?"}
                            class="btn btn-ghost btn-xs text-error"
                          >
                            Remove
                          </button>
                        <% end %>
                      </td>
                    <% end %>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <!-- Pending Invitations (Owners only) -->
          <%= if @can_manage_members && @pending_invitations != [] do %>
            <div class="divider"></div>
            <div>
              <h4 class="font-semibold mb-2">Pending Invitations</h4>
              <div class="overflow-x-auto">
                <table class="table table-zebra w-full">
                  <thead>
                    <tr>
                      <th>Email</th>
                      <th>Role</th>
                      <th>Sent</th>
                      <th>Expires</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for invitation <- @pending_invitations do %>
                      <tr>
                        <td>{invitation.invited_email}</td>
                        <td>
                          <div class="badge badge-outline">{String.capitalize(invitation.role)}</div>
                        </td>
                        <td class="text-sm">{Calendar.strftime(invitation.inserted_at, "%b %d")}</td>
                        <td class="text-sm">{Calendar.strftime(invitation.expires_at, "%b %d")}</td>
                        <td>
                          <div class="flex gap-1">
                            <button
                              type="button"
                              phx-click="resend_invitation"
                              phx-value-id={invitation.id}
                              class="btn btn-ghost btn-xs"
                            >
                              Resend
                            </button>
                            <button
                              type="button"
                              phx-click="cancel_invitation"
                              phx-value-id={invitation.id}
                              data-confirm="Cancel this invitation?"
                              class="btn btn-ghost btn-xs"
                            >
                              Cancel
                            </button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Danger Zone -->
      <div class="card bg-base-200 shadow-xl border-2 border-error/20">
        <div class="card-body">
          <h3 class="card-title text-error">Danger Zone</h3>
          <p class="text-sm opacity-70">
            Deleting a company is permanent and cannot be undone. All campaigns, sorties, and pilot data will be lost.
          </p>

          <div class="card-actions justify-end mt-4">
            <button
              type="button"
              phx-click="delete_company"
              phx-value-id={@company.id}
              data-confirm="Are you sure you want to delete this company? This action cannot be undone."
              class="btn btn-error"
            >
              Delete Company
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
