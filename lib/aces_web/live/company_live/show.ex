defmodule AcesWeb.CompanyLive.Show do
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns, ChangesetHelpers}
  alias Aces.Companies.Authorization
  alias Aces.Companies.Units, as: CompanyUnits

  on_mount {AcesWeb.UserAuthLive, :default}

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
        active_campaign = Campaigns.get_active_campaign(company)

        {:ok,
         socket
         |> assign(:company, company)
         |> assign(:active_campaign, active_campaign)
         |> assign(:page_title, company.name)
         |> assign(:show_unit_search, false)
         |> assign(:show_pilot_form, false)
         |> assign(:show_unit_edit, false)
         |> assign(:editing_unit, nil)}
      end
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_unit", _params, socket) do
    company = socket.assigns.company

    if company.status == "active" do
      {:noreply,
       socket
       |> put_flash(:error, "Cannot add units with PV to finalized companies. Units must be purchased with SP.")}
    else
      {:noreply, assign(socket, :show_unit_search, true)}
    end
  end

  def handle_event("hire_pilot", _params, socket) do
    {:noreply, assign(socket, :show_pilot_form, true)}
  end

  def handle_event("close_pilot_form", _params, socket) do
    {:noreply, assign(socket, :show_pilot_form, false)}
  end

  def handle_event("edit_unit", %{"unit_id" => unit_id_str}, socket) do
    unit_id = String.to_integer(unit_id_str)
    company = socket.assigns.company
    
    case Enum.find(company.company_units, &(&1.id == unit_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unit not found")}
      
      unit ->
        {:noreply, 
         socket
         |> assign(:show_unit_edit, true)
         |> assign(:editing_unit, unit)}
    end
  end

  def handle_event("close_unit_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_unit_edit, false)
     |> assign(:editing_unit, nil)}
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
  def handle_info({AcesWeb.CompanyLive.PilotFormComponent, {:saved, _pilot}}, socket) do
    updated_company = Companies.get_company_with_stats!(socket.assigns.company.id)
    
    {:noreply,
     socket
     |> assign(:company, updated_company)
     |> assign(:show_pilot_form, false)}
  end

  def handle_info({AcesWeb.CompanyLive.PilotHireComponent, {:saved, _pilot, updated_company}}, socket) do
    {:noreply,
     socket
     |> assign(:company, Companies.get_company_with_stats!(updated_company.id))
     |> assign(:show_pilot_form, false)}
  end

  def handle_info({AcesWeb.CompanyLive.UnitEditComponent, {:saved, _unit}}, socket) do
    updated_company = Companies.get_company_with_stats!(socket.assigns.company.id)

    {:noreply,
     socket
     |> assign(:company, updated_company)
     |> assign(:show_unit_edit, false)
     |> assign(:editing_unit, nil)}
  end

  def handle_info({AcesWeb.Components.UnitSearchModal, :close_modal}, socket) do
    {:noreply, assign(socket, :show_unit_search, false)}
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
           |> assign(:show_unit_search, false)}

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <.link navigate={~p"/companies"} class="btn btn-ghost btn-sm">
            ← Back to Companies
          </.link>
        </div>

        <h1 class="text-4xl font-bold mb-2">{@company.name}</h1>
        <%= if @company.description do %>
          <p class="text-lg opacity-70">{@company.description}</p>
        <% end %>
      </div>

      <div class="grid grid-cols-2 gap-3 md:gap-6 lg:grid-cols-5 mb-8">
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

      <div class="divider"></div>

      <div class="mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-2xl font-bold">Pilot Roster</h2>
          <%= if @company.status == "active" do %>
            <button
              type="button"
              phx-click="hire_pilot"
              class="btn btn-primary"
              disabled={@company.warchest_balance < 150}
              title="Hire pilot for 150 SP"
            >
              Hire Pilot (150 SP)
            </button>
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
            <span>No pilots in your company yet. <%= if @company.status == "active", do: "Hire pilots to operate your units!", else: "Pilots are added during company creation." %></span>
          </div>
        <% else %>
          <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
            <%= for pilot <- @company.pilots do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body">
                  <h3 class="card-title">
                    <%= if pilot.callsign && String.trim(pilot.callsign) != "" do %>
                      "<%= pilot.callsign %>" <%= pilot.name %>
                    <% else %>
                      <%= pilot.name %>
                    <% end %>
                  </h3>
                  
                  <%= if pilot.description && String.trim(pilot.description) != "" do %>
                    <p class="text-sm opacity-70"><%= pilot.description %></p>
                  <% end %>
                  
                  <div class="flex flex-wrap gap-2 mt-2">
                    <div class="badge badge-primary">Skill {pilot.skill_level}</div>
                    <div class="badge badge-secondary">Edge {pilot.edge_tokens}</div>
                    <div class={[
                      "badge",
                      pilot.status == "active" && "badge-success",
                      pilot.status == "wounded" && "badge-warning",
                      pilot.status == "deceased" && "badge-error"
                    ]}>
                      {String.capitalize(pilot.status)}
                    </div>
                  </div>

                  <div class="mt-2 text-sm opacity-70">
                    <div>SP Earned: {pilot.sp_earned}</div>
                    <div>Sorties: {pilot.sorties_participated}</div>
                    <%= if pilot.assigned_unit do %>
                      <div class="text-info">
                        Assigned: {Aces.Units.MasterUnit.display_name(pilot.assigned_unit.master_unit)}
                      </div>
                    <% else %>
                      <div class="text-gray-500">Unassigned</div>
                    <% end %>
                    <%= if pilot.mvp_awards > 0 do %>
                      <div>MVP Awards: {pilot.mvp_awards}</div>
                    <% end %>
                    <%= if pilot.wounds > 0 do %>
                      <div class="text-warning">Wounds: {pilot.wounds}</div>
                    <% end %>
                  </div>
                  
                  <div class="card-actions justify-end">
                    <button class="btn btn-ghost btn-sm md:btn-xs">Edit</button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <div class="divider"></div>

      <!-- Active Campaign Section -->
      <div class="mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-2xl font-bold">Active Campaign</h2>
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
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h3 class="card-title">{@active_campaign.name}</h3>
              <%= if @active_campaign.description do %>
                <p class="opacity-70">{@active_campaign.description}</p>
              <% end %>
              
              <div class="grid gap-4 md:grid-cols-4 mt-4">
                <div class="stat bg-base-200 rounded-lg">
                  <div class="stat-title text-xs">Difficulty</div>
                  <div class="stat-value text-lg">{String.capitalize(@active_campaign.difficulty_level)}</div>
                </div>
                
                <div class="stat bg-base-200 rounded-lg">
                  <div class="stat-title text-xs">Warchest</div>
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
          </div>
        <% else %>
          <div class="alert alert-info">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
            </svg>
            <span>
              No active campaign. 
              <%= if @company.status == "active" do %>
                Start a new campaign to begin deploying your company on missions!
              <% else %>
                Complete company setup to start campaigns.
              <% end %>
            </span>
          </div>
        <% end %>
      </div>

      <div class="divider"></div>

      <div class="mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-2xl font-bold">Unit Roster</h2>
          <%= if @company.status == "draft" do %>
            <button
              type="button"
              phx-click="add_unit"
              class="btn btn-primary"
            >
              Add Unit (PV)
            </button>
          <% else %>
            <div class="text-sm opacity-70">
              PV purchases disabled for finalized companies
            </div>
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
            <span>No units in roster yet. Add your first unit to get started!</span>
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

      <div class="divider"></div>

      <div class="mb-8">
        <h2 class="text-2xl font-bold mb-4">Company Settings</h2>

        <div class="card bg-base-200 shadow-xl">
          <div class="card-body">
            <h3 class="card-title">Danger Zone</h3>
            <p class="text-sm opacity-70">
              Deleting a company is permanent and cannot be undone.
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

      <!-- Unit Search Modal -->
      <.live_component
        module={AcesWeb.Components.UnitSearchModal}
        id="unit-search"
        show={@show_unit_search}
        mode={:pv_budget}
        budget={@company.stats.pv_remaining}
        error={nil}
      />

      <!-- Pilot Hiring Modal -->
      <%= if @show_pilot_form do %>
        <div class="modal modal-open">
          <div class="modal-box w-11/12 max-w-2xl">
            <div class="flex justify-between items-center mb-4">
              <h3 class="font-bold text-lg">Hire New Pilot</h3>
              <button
                type="button"
                phx-click="close_pilot_form"
                class="btn btn-sm btn-circle btn-ghost"
              >
                ✕
              </button>
            </div>

            <.live_component
              module={AcesWeb.CompanyLive.PilotHireComponent}
              id={:hire_pilot}
              company={@company}
              patch={~p"/companies/#{@company}"}
            />
          </div>
        </div>
      <% end %>

      <!-- Unit Edit Modal -->
      <%= if @show_unit_edit && @editing_unit do %>
        <div class="modal modal-open">
          <div class="modal-box w-11/12 max-w-2xl">
            <div class="flex justify-between items-center mb-4">
              <h3 class="font-bold text-lg">Edit Unit</h3>
              <button
                type="button"
                phx-click="close_unit_edit"
                class="btn btn-sm btn-circle btn-ghost"
              >
                ✕
              </button>
            </div>

            <.live_component
              module={AcesWeb.CompanyLive.UnitEditComponent}
              id={:edit_unit}
              action={:edit_unit}
              unit={@editing_unit}
              company={@company}
              patch={~p"/companies/#{@company}"}
            />
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
