defmodule AcesWeb.CompanyLive.Show do
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
  alias Aces.Companies.Authorization
  alias Aces.Companies.Units, as: CompanyUnits
  alias Aces.Units

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
         |> assign(:unit_search_term, "")
         |> assign(:search_results, [])
         |> assign(:search_loading, false)
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

  def handle_event("close_unit_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_unit_search, false)
     |> assign(:unit_search_term, "")
     |> assign(:search_results, [])
     |> assign(:search_loading, false)}
  end

  def handle_event("search_units", %{"value" => search_term}, socket) do
    search_term = String.trim(search_term)
    require Logger
    Logger.debug("Search event received for term: '#{search_term}'")

    socket =
      if String.length(search_term) >= 2 do
        Logger.debug("Term length >= 2, starting search...")

        socket =
          socket
          |> assign(:unit_search_term, search_term)
          |> assign(:search_loading, true)

        # Perform search asynchronously
        Logger.debug("Sending perform_search message to self()")
        send(self(), {:perform_search, search_term})
        socket
      else
        Logger.debug("Term too short, clearing results")
        socket
        |> assign(:unit_search_term, search_term)
        |> assign(:search_results, [])
        |> assign(:search_loading, false)
      end

    {:noreply, socket}
  end

  def handle_event("select_unit", %{"mul_id" => mul_id_str}, socket) do
    mul_id = String.to_integer(mul_id_str)
    company = socket.assigns.company
    user = socket.assigns.current_scope.user

    if Authorization.can?(:edit_company, user, company) do
      case CompanyUnits.purchase_unit_for_company(company, mul_id) do
        {:ok, _company_unit} ->
          # Reload the company with updated stats
          updated_company = Companies.get_company_with_stats!(company.id)

          {:noreply,
           socket
           |> assign(:company, updated_company)
           |> put_flash(:info, "Unit successfully added to roster!")
           |> assign(:show_unit_search, false)}

        {:error, %Ecto.Changeset{} = changeset} ->
          error_message = format_changeset_errors(changeset)

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

  def handle_info({:perform_search, search_term}, socket) do
    require Logger
    Logger.debug("handle_info received perform_search for: '#{search_term}'")
    Logger.debug("Current unit_search_term: '#{socket.assigns.unit_search_term}'")

    # Only perform search if the search term hasn't changed
    if socket.assigns.unit_search_term == search_term do
      Logger.debug("Search terms match, performing search...")
      try do
        search_results = Units.search_units(search_term, unit_type: "battlemech")
        Logger.debug("Search returned #{length(search_results)} results")

        {:noreply,
         socket
         |> assign(:search_results, search_results)
         |> assign(:search_loading, false)}
      rescue
        error ->
          Logger.error("Search failed for '#{search_term}': #{inspect(error)}")

          {:noreply,
           socket
           |> assign(:search_results, [])
           |> assign(:search_loading, false)
           |> put_flash(:error, "Search failed. Please try again.")}
      end
    else
      Logger.debug("Search terms don't match, ignoring stale search")
      {:noreply, socket}
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

      <div class="grid gap-6 md:grid-cols-5 mb-8">
        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Total Units</div>
          <div class="stat-value text-primary">{@company.stats.unit_count}</div>
          <div class="stat-desc">In roster</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Pilots</div>
          <div class="stat-value text-info">{@company.stats.pilot_count}</div>
          <div class="stat-desc">Recruited</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">PV Budget</div>
          <div class="stat-value text-accent">
            {@company.stats.pv_remaining}/{@company.stats.pv_budget}
          </div>
          <div class="stat-desc">{@company.stats.pv_used} PV used</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Warchest</div>
          <div class="stat-value text-secondary">{@company.stats.warchest_balance}</div>
          <div class="stat-desc">Support Points available</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Last Updated</div>
          <div class="stat-value text-sm">
            {Calendar.strftime(@company.stats.last_modified, "%b %d, %Y")}
          </div>
          <div class="stat-desc">{Calendar.strftime(@company.stats.last_modified, "%I:%M %p")}</div>
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
                    <button class="btn btn-ghost btn-xs">Edit</button>
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
                  <th>Unit Details</th>
                  <th>Custom Name</th>
                  <th>Status</th>
                  <th>Pilot</th>
                  <th>Skill</th>
                  <th>Cost (SP)</th>
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
                        <div class="font-semibold">{Aces.Units.MasterUnit.display_name(unit.master_unit)}</div>
                        <div class="flex gap-1 mt-1">
                          <div class="badge badge-outline badge-sm">
                            {String.replace(unit.master_unit.unit_type, "_", " ") |> String.capitalize()}
                          </div>
                          <%= if unit.master_unit.tonnage do %>
                            <div class="badge badge-neutral badge-sm">{unit.master_unit.tonnage}t</div>
                          <% end %>
                          <%= if unit.master_unit.point_value do %>
                            <div class="badge badge-accent badge-sm">{unit.master_unit.point_value} PV</div>
                          <% end %>
                        </div>
                      <% else %>
                        <div class="font-semibold text-gray-500">Unknown Unit</div>
                      <% end %>
                    </td>
                    <td>{unit.custom_name || "-"}</td>
                    <td>
                      <div class={[
                        "badge",
                        unit.status == "operational" && "badge-success",
                        unit.status == "damaged" && "badge-warning",
                        unit.status == "destroyed" && "badge-error"
                      ]}>
                        {unit.status}
                      </div>
                    </td>
                    <td>
                      <%= if unit.pilot do %>
                        <span class="text-sm">{unit.pilot.name}</span>
                      <% else %>
                        <span class="text-gray-500 text-sm">Unassigned</span>
                      <% end %>
                    </td>
                    <td>
                      <div class="badge badge-outline">
                        Skill {Aces.Companies.CompanyUnit.effective_skill_level(unit)}
                      </div>
                    </td>
                    <td>{unit.purchase_cost_sp} SP</td>
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
                        class="btn btn-ghost btn-xs"
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
      <%= if @show_unit_search do %>
        <div class="modal modal-open">
          <div class="modal-box w-11/12 max-w-4xl">
            <div class="flex justify-between items-center mb-4">
              <h3 class="font-bold text-lg">Add Unit to Roster</h3>
              <button
                type="button"
                phx-click="close_unit_search"
                class="btn btn-sm btn-circle btn-ghost"
              >
                ✕
              </button>
            </div>

            <div class="mb-4">
              <input
                type="text"
                name="search"
                placeholder="Search for units (e.g. Atlas, Timber Wolf, Locust...)"
                class="input input-bordered w-full"
                value={@unit_search_term}
                phx-keyup="search_units"
                phx-debounce="300"
              />
              <p class="text-sm text-gray-600 mt-2">
                Units are sourced from
                <a href="https://masterunitlist.info" target="_blank" class="link">Master Unit List</a>
                with respect and attribution.
              </p>
            </div>

            <div class="divider"></div>

            <div class="max-h-96 overflow-y-auto">
              <%= if @search_loading do %>
                <div class="flex justify-center py-8">
                  <span class="loading loading-spinner loading-lg"></span>
                </div>
              <% else %>
                <%= if length(@search_results) > 0 do %>
                  <div class="grid gap-3">
                    <%= for unit <- @search_results do %>
                      <div class="card bg-base-100 shadow compact">
                        <div class="card-body">
                          <div class="flex justify-between items-start">
                            <div>
                              <h4 class="card-title text-base">
                                <%= Aces.Units.MasterUnit.display_name(unit) %>
                              </h4>
                              <div class="flex gap-2 mt-2">
                                <div class="badge badge-outline">
                                  {String.replace(unit.unit_type, "_", " ") |> String.capitalize()}
                                </div>
                                <%= if unit.tonnage do %>
                                  <div class="badge badge-neutral">{unit.tonnage} tons</div>
                                <% end %>
                                <%= if unit.point_value do %>
                                  <div class="badge badge-accent">{unit.point_value} PV</div>
                                <% end %>
                              </div>
                              <%= if unit.role do %>
                                <p class="text-sm text-gray-600 mt-1">Role: {unit.role}</p>
                              <% end %>
                              <%= if unit.factions && map_size(unit.factions) > 0 do %>
                                <div class="flex gap-1 mt-2">
                                  <%= for faction <- Enum.take(Map.keys(unit.factions), 3) do %>
                                    <div class="badge badge-ghost badge-xs">{String.capitalize(faction)}</div>
                                  <% end %>
                                  <%= if map_size(unit.factions) > 3 do %>
                                    <div class="badge badge-ghost badge-xs">+{map_size(unit.factions) - 3}</div>
                                  <% end %>
                                </div>
                              <% end %>
                            </div>
                            <div class="flex flex-col gap-2">
                              <%= if unit.point_value && unit.point_value <= @company.stats.pv_remaining do %>
                                <button
                                  type="button"
                                  phx-click="select_unit"
                                  phx-value-mul_id={unit.mul_id}
                                  class="btn btn-primary btn-sm"
                                >
                                  Add Unit
                                </button>
                              <% else %>
                                <button
                                  type="button"
                                  disabled
                                  class="btn btn-disabled btn-sm"
                                  title="Insufficient PV budget"
                                >
                                  Too Expensive
                                </button>
                              <% end %>
                              <div class="flex gap-1">
                                <a
                                  href={Aces.Units.MasterUnit.mul_url(unit)}
                                  target="_blank"
                                  class="btn btn-ghost btn-xs"
                                  title="View on MasterUnitList.info"
                                >
                                  MUL ↗
                                </a>
                                <a
                                  href={Aces.Units.MasterUnit.sarna_url(unit)}
                                  target="_blank"
                                  class="btn btn-ghost btn-xs"
                                  title="Search on Sarna.net"
                                >
                                  Sarna ↗
                                </a>
                              </div>
                            </div>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <%= if @unit_search_term != "" do %>
                    <div class="text-center py-8">
                      <p class="text-gray-600">No units found for "{@unit_search_term}"</p>
                      <p class="text-sm text-gray-500 mt-2">
                        Try searching by chassis name (e.g., "Atlas" instead of "AS7-D")
                      </p>
                    </div>
                  <% else %>
                    <div class="text-center py-8">
                      <p class="text-gray-600">Search for units to add to your company roster</p>
                    </div>
                  <% end %>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>

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

  defp format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end
end
