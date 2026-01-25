defmodule AcesWeb.CompanyLive.Draft do
  use AcesWeb, :live_view

  alias Aces.Companies
  alias Aces.Companies.Authorization
  alias Aces.Companies.Pilots, as: CompanyPilots
  alias Aces.Companies.Units, as: CompanyUnits
  alias Aces.Units
  alias AcesWeb.Layouts

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    company = Companies.get_company_with_stats!(id)
    user = socket.assigns.current_scope.user

    unless Authorization.can?(:edit_company, user, company) do
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to edit this company")
       |> redirect(to: ~p"/companies")}
    else
      if company.status != "draft" do
        {:ok,
         socket
         |> put_flash(:error, "Company is no longer in draft status")
         |> redirect(to: ~p"/companies/#{company}")}
      else
        {:ok,
         socket
         |> assign(:company, company)
         |> assign(:page_title, "Setup: #{company.name}")
         |> assign(:show_unit_search, false)
         |> assign(:unit_search_term, "")
         |> assign(:search_results, [])
         |> assign(:search_loading, false)
         |> assign(:unit_add_error, nil)
         |> assign(:search_filter_eras, ["ilclan", "dark_age"])
         |> assign(:search_filter_faction, "mercenary")
         |> assign(:search_filter_type, nil)
         |> assign(:show_pilot_form, false)
         |> assign(:pilot_form_action, :new)
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
    {:noreply,
     socket
     |> assign(:show_unit_search, true)
     |> assign(:unit_add_error, nil)
     |> assign(:search_filter_eras, ["ilclan", "dark_age"])
     |> assign(:search_filter_faction, "mercenary")
     |> assign(:search_filter_type, nil)}
  end

  def handle_event("close_unit_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_unit_search, false)
     |> assign(:unit_search_term, "")
     |> assign(:search_results, [])
     |> assign(:search_loading, false)
     |> assign(:unit_add_error, nil)}
  end

  def handle_event("toggle_era_filter", %{"era" => era}, socket) do
    current_eras = socket.assigns.search_filter_eras

    new_eras =
      if era in current_eras do
        List.delete(current_eras, era)
      else
        [era | current_eras]
      end

    socket = assign(socket, :search_filter_eras, new_eras)

    # Re-run search immediately if we have a search term
    {:noreply, maybe_run_search(socket)}
  end

  def handle_event("set_faction_filter", %{"faction" => faction}, socket) do
    socket = assign(socket, :search_filter_faction, faction)

    # Re-run search immediately if we have a search term
    {:noreply, maybe_run_search(socket)}
  end

  def handle_event("set_type_filter", %{"type" => type}, socket) do
    type_value = if type == "", do: nil, else: type
    socket = assign(socket, :search_filter_type, type_value)

    # Re-run search immediately if we have a search term
    {:noreply, maybe_run_search(socket)}
  end

  def handle_event("search_units", %{"value" => search_term}, socket) do
    search_term = String.trim(search_term)

    socket =
      if String.length(search_term) >= 2 do
        socket =
          socket
          |> assign(:unit_search_term, search_term)
          |> assign(:search_loading, true)
          |> assign(:unit_add_error, nil)

        send(self(), {:perform_search, search_term})
        socket
      else
        socket
        |> assign(:unit_search_term, search_term)
        |> assign(:search_results, [])
        |> assign(:search_loading, false)
        |> assign(:unit_add_error, nil)
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
          updated_company = Companies.get_company_with_stats!(company.id)

          {:noreply,
           socket
           |> assign(:company, updated_company)
           |> put_flash(:info, "Unit successfully added to roster!")
           |> assign(:show_unit_search, false)
           |> assign(:unit_add_error, nil)}

        {:error, %Ecto.Changeset{} = changeset} ->
          error_message = format_changeset_errors(changeset)
          {:noreply, assign(socket, :unit_add_error, error_message)}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to add units to this company")}
    end
  end

  def handle_event("add_pilot", _params, socket) do
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

  def handle_event("remove_unit", %{"unit_id" => unit_id_str}, socket) do
    unit_id = String.to_integer(unit_id_str)
    company = socket.assigns.company
    user = socket.assigns.current_scope.user

    if Authorization.can?(:edit_company, user, company) do
      company_unit = Enum.find(company.company_units, &(&1.id == unit_id))
      
      if company_unit do
        case CompanyUnits.remove_unit_from_company(company_unit) do
          {:ok, _} ->
            updated_company = Companies.get_company_with_stats!(company.id)

            {:noreply,
             socket
             |> assign(:company, updated_company)
             |> put_flash(:info, "Unit removed from roster!")}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to remove unit")}
        end
      else
        {:noreply,
         socket
         |> put_flash(:error, "Unit not found")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to remove units from this company")}
    end
  end

  def handle_event("remove_pilot", %{"pilot_id" => pilot_id_str}, socket) do
    pilot_id = String.to_integer(pilot_id_str)
    company = socket.assigns.company
    user = socket.assigns.current_scope.user

    if Authorization.can?(:edit_company, user, company) do
      pilot = Enum.find(company.pilots, &(&1.id == pilot_id))
      
      if pilot do
        case CompanyPilots.delete_pilot(pilot) do
          {:ok, _} ->
            updated_company = Companies.get_company_with_stats!(company.id)

            {:noreply,
             socket
             |> assign(:company, updated_company)
             |> put_flash(:info, "Pilot removed from company!")}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to remove pilot")}
        end
      else
        {:noreply,
         socket
         |> put_flash(:error, "Pilot not found")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to remove pilots from this company")}
    end
  end

  def handle_event("finalize_company", _params, socket) do
    company = socket.assigns.company
    user = socket.assigns.current_scope.user

    if Authorization.can?(:edit_company, user, company) do
      case Companies.finalize_company(company) do
        {:ok, finalized_company} ->
          {:noreply,
           socket
           |> put_flash(:info, "Company finalized successfully! Any unused PV has been converted to SP.")
           |> redirect(to: ~p"/companies/#{finalized_company}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          error_message = format_changeset_errors(changeset)
          {:noreply,
           socket
           |> put_flash(:error, "Failed to finalize company: #{error_message}")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to finalize this company")}
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

  def handle_info({AcesWeb.CompanyLive.UnitEditComponent, {:saved, _unit}}, socket) do
    updated_company = Companies.get_company_with_stats!(socket.assigns.company.id)
    
    {:noreply,
     socket
     |> assign(:company, updated_company)
     |> assign(:show_unit_edit, false)
     |> assign(:editing_unit, nil)}
  end

  def handle_info({:perform_search, search_term}, socket) do
    if socket.assigns.unit_search_term == search_term do
      try do
        # Build search options from filters
        opts = build_search_opts(socket.assigns)
        search_results = Units.search_units(search_term, opts)

        {:noreply,
         socket
         |> assign(:search_results, search_results)
         |> assign(:search_loading, false)}
      rescue
        _error ->
          {:noreply,
           socket
           |> assign(:search_results, [])
           |> assign(:search_loading, false)
           |> put_flash(:error, "Search failed. Please try again.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp build_search_opts(assigns) do
    opts = []

    # Add unit type filter if set
    opts =
      if assigns.search_filter_type do
        [{:unit_type, assigns.search_filter_type} | opts]
      else
        opts
      end

    # Add era + faction filter if both are set
    opts =
      if length(assigns.search_filter_eras) > 0 and assigns.search_filter_faction do
        [{:era_faction, {assigns.search_filter_eras, assigns.search_filter_faction}} | opts]
      else
        opts
      end

    opts
  end

  # Helper to run search immediately when filters change
  defp maybe_run_search(socket) do
    search_term = socket.assigns.unit_search_term

    if String.length(search_term) >= 2 do
      try do
        opts = build_search_opts(socket.assigns)
        search_results = Units.search_units(search_term, opts)

        socket
        |> assign(:search_results, search_results)
        |> assign(:search_loading, false)
      rescue
        _error ->
          socket
          |> assign(:search_results, [])
          |> assign(:search_loading, false)
      end
    else
      socket
    end
  end

  defp format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="container mx-auto px-4 py-8">
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <.link navigate={~p"/companies"} class="btn btn-ghost btn-sm">
            ← Back to Companies
          </.link>
        </div>

        <div class="flex items-center gap-4 mb-4">
          <h1 class="text-4xl font-bold">Company Setup: {@company.name}</h1>
          <div class="badge badge-warning badge-lg">DRAFT</div>
        </div>

        <%= if @company.description do %>
          <p class="text-lg opacity-70">{@company.description}</p>
        <% end %>

        <div class="alert alert-info mt-4">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
          </svg>
          <span>
            You have <strong>{@company.stats.pv_budget} PV</strong> to build your company roster. 
            Any unused PV will be converted to SP at a rate of <strong>1 PV = 40 SP</strong> when you finalize this company.
          </span>
        </div>
      </div>

      <div class="grid gap-6 md:grid-cols-4 mb-8">
        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">PV Budget</div>
          <div class="stat-value text-accent">
            {@company.stats.pv_remaining}/{@company.stats.pv_budget}
          </div>
          <div class="stat-desc">{@company.stats.pv_used} PV used</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Units Selected</div>
          <div class="stat-value text-primary">{@company.stats.unit_count}</div>
          <div class="stat-desc">In your roster</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Pilots Recruited</div>
          <div class="stat-value text-info">{@company.stats.pilot_count}/6</div>
          <div class="stat-desc">Max 6 during setup</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Future Warchest</div>
          <div class="stat-value text-secondary">
            {@company.stats.warchest_balance + (@company.stats.pv_remaining * 40)}
          </div>
          <div class="stat-desc">SP after finalization</div>
        </div>
      </div>

      <div class="divider"></div>

      <div class="mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-2xl font-bold">Recruit Your Pilots</h2>
          <button
            type="button"
            phx-click="add_pilot"
            class="btn btn-primary"
            disabled={length(@company.pilots) >= 6}
          >
            Add Pilot
          </button>
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
            <span>No pilots recruited yet. Add skilled pilots to operate your units!</span>
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
                    <div class="badge badge-success">{String.capitalize(pilot.status)}</div>
                  </div>

                  <div class="mt-2 text-sm opacity-70">
                    <%= if pilot.assigned_unit do %>
                      <div class="text-info">
                        Assigned: {Aces.Units.MasterUnit.display_name(pilot.assigned_unit.master_unit)}
                      </div>
                    <% else %>
                      <div class="text-gray-500">Unassigned</div>
                    <% end %>
                  </div>
                  
                  <div class="card-actions justify-end">
                    <button 
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="remove_pilot"
                      phx-value-pilot_id={pilot.id}
                      data-confirm="Are you sure you want to remove this pilot from the company?"
                    >
                      Remove
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <div class="divider"></div>

      <div class="mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-2xl font-bold">Build Your Roster</h2>
          <button
            type="button"
            phx-click="add_unit"
            class="btn btn-primary"
          >
            Add Unit
          </button>
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
            <span>No units selected yet. Add your first unit to get started!</span>
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
                      <button 
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="remove_unit"
                        phx-value-unit_id={unit.id}
                        data-confirm="Are you sure you want to remove this unit from the roster? This will restore the PV to your budget."
                      >
                        Remove
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
        <h2 class="text-2xl font-bold mb-4">Finalize Company</h2>

        <div class="card bg-base-200 shadow-xl">
          <div class="card-body">
            <h3 class="card-title">Ready to Deploy?</h3>
            <p class="text-sm opacity-70 mb-4">
              Once you finalize this company, you won't be able to change the initial roster. 
              Any unused PV ({@company.stats.pv_remaining} PV) will be converted to Support Points 
              ({@company.stats.pv_remaining * 40} SP) and added to your warchest.
            </p>

            <div class="bg-base-100 p-4 rounded-lg mb-4">
              <h4 class="font-semibold mb-2">Summary:</h4>
              <ul class="text-sm space-y-1">
                <li>• Units in roster: {@company.stats.unit_count}</li>
                <li>• PV used: {@company.stats.pv_used}/{@company.stats.pv_budget}</li>
                <li>• Starting warchest: {@company.stats.warchest_balance} SP</li>
                <li>• Bonus SP from unused PV: {@company.stats.pv_remaining * 40} SP</li>
                <li><strong>• Total starting warchest: {@company.stats.warchest_balance + (@company.stats.pv_remaining * 40)} SP</strong></li>
              </ul>
            </div>

            <div class="card-actions justify-end">
              <button
                type="button"
                phx-click="finalize_company"
                class="btn btn-success"
                data-confirm="Are you sure you want to finalize this company? This action cannot be undone."
              >
                Finalize Company
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

            <!-- Filters -->
            <div class="bg-base-200 p-4 rounded-lg mb-4">
              <div class="flex flex-wrap gap-4">
                <!-- Era Filter -->
                <div>
                  <label class="label">
                    <span class="label-text font-semibold">Era</span>
                  </label>
                  <div class="flex flex-wrap gap-2">
                    <button
                      type="button"
                      phx-click="toggle_era_filter"
                      phx-value-era="ilclan"
                      class={"btn btn-sm #{if "ilclan" in @search_filter_eras, do: "btn-primary", else: "btn-outline"}"}
                    >
                      ilClan
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_era_filter"
                      phx-value-era="dark_age"
                      class={"btn btn-sm #{if "dark_age" in @search_filter_eras, do: "btn-primary", else: "btn-outline"}"}
                    >
                      Dark Age
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_era_filter"
                      phx-value-era="late_republic"
                      class={"btn btn-sm #{if "late_republic" in @search_filter_eras, do: "btn-primary", else: "btn-outline"}"}
                    >
                      Late Republic
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_era_filter"
                      phx-value-era="early_republic"
                      class={"btn btn-sm #{if "early_republic" in @search_filter_eras, do: "btn-primary", else: "btn-outline"}"}
                    >
                      Early Republic
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_era_filter"
                      phx-value-era="clan_invasion"
                      class={"btn btn-sm #{if "clan_invasion" in @search_filter_eras, do: "btn-primary", else: "btn-outline"}"}
                    >
                      Clan Invasion
                    </button>
                  </div>
                </div>

                <!-- Faction Filter -->
                <div>
                  <label class="label">
                    <span class="label-text font-semibold">Faction</span>
                  </label>
                  <form phx-change="set_faction_filter">
                  <select
                    class="select select-bordered select-sm"
                    name="faction"
                  >
                    <option value="mercenary" selected={@search_filter_faction == "mercenary"}>Mercenary</option>
                    <optgroup label="Inner Sphere">
                      <option value="capellan_confederation" selected={@search_filter_faction == "capellan_confederation"}>Capellan Confederation</option>
                      <option value="draconis_combine" selected={@search_filter_faction == "draconis_combine"}>Draconis Combine</option>
                      <option value="federated_suns" selected={@search_filter_faction == "federated_suns"}>Federated Suns</option>
                      <option value="free_worlds_league" selected={@search_filter_faction == "free_worlds_league"}>Free Worlds League</option>
                      <option value="lyran_commonwealth" selected={@search_filter_faction == "lyran_commonwealth"}>Lyran Commonwealth</option>
                      <option value="republic_of_the_sphere" selected={@search_filter_faction == "republic_of_the_sphere"}>Republic of the Sphere</option>
                    </optgroup>
                    <optgroup label="Clans">
                      <option value="clan_wolf" selected={@search_filter_faction == "clan_wolf"}>Clan Wolf</option>
                      <option value="clan_jade_falcon" selected={@search_filter_faction == "clan_jade_falcon"}>Clan Jade Falcon</option>
                      <option value="clan_ghost_bear" selected={@search_filter_faction == "clan_ghost_bear"}>Clan Ghost Bear</option>
                      <option value="clan_sea_fox" selected={@search_filter_faction == "clan_sea_fox"}>Clan Sea Fox</option>
                      <option value="clan_hell_horses" selected={@search_filter_faction == "clan_hell_horses"}>Clan Hell's Horses</option>
                    </optgroup>
                  </select>
                </form>
                </div>

                <!-- Unit Type Filter -->
                <div>
                  <label class="label">
                    <span class="label-text font-semibold">Unit Type</span>
                  </label>
                  <form phx-change="set_type_filter">
                    <select
                      class="select select-bordered select-sm"
                      name="type"
                    >
                      <option value="" selected={@search_filter_type == nil}>All Types</option>
                      <option value="battlemech" selected={@search_filter_type == "battlemech"}>BattleMech</option>
                      <option value="combat_vehicle" selected={@search_filter_type == "combat_vehicle"}>Combat Vehicle</option>
                      <option value="battle_armor" selected={@search_filter_type == "battle_armor"}>Battle Armor</option>
                      <option value="conventional_infantry" selected={@search_filter_type == "conventional_infantry"}>Infantry</option>
                      <option value="protomech" selected={@search_filter_type == "protomech"}>ProtoMech</option>
                    </select>
                  </form>
                </div>
              </div>
            </div>

            <!-- Error Display -->
            <%= if @unit_add_error do %>
              <div class="alert alert-error mb-4">
                <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <span>{@unit_add_error}</span>
              </div>
            <% end %>

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
                              <!-- Alpha Strike Stats -->
                              <div class="flex flex-wrap gap-x-4 gap-y-1 mt-2 text-xs text-gray-600">
                                <%= if unit.bf_move do %>
                                  <span title="Movement"><span class="font-semibold">MV:</span> {unit.bf_move}</span>
                                <% end %>
                                <%= if unit.bf_armor || unit.bf_structure do %>
                                  <span title="Armor / Structure"><span class="font-semibold">A/S:</span> {unit.bf_armor || 0}/{unit.bf_structure || 0}</span>
                                <% end %>
                                <%= if unit.bf_damage_short || unit.bf_damage_medium || unit.bf_damage_long do %>
                                  <span title="Damage (Short/Medium/Long)"><span class="font-semibold">DMG:</span> {unit.bf_damage_short || "-"}/{unit.bf_damage_medium || "-"}/{unit.bf_damage_long || "-"}</span>
                                <% end %>
                                <%= if unit.bf_overheat && unit.bf_overheat > 0 do %>
                                  <span title="Overheat"><span class="font-semibold">OV:</span> {unit.bf_overheat}</span>
                                <% end %>
                              </div>
                              <%= if unit.bf_abilities && unit.bf_abilities != "" do %>
                                <p class="text-xs text-gray-500 mt-1" title="Special Abilities">
                                  <span class="font-semibold">Specials:</span> {unit.bf_abilities}
                                </p>
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

      <!-- Pilot Form Modal -->
      <%= if @show_pilot_form do %>
        <div class="modal modal-open">
          <div class="modal-box w-11/12 max-w-2xl">
            <div class="flex justify-between items-center mb-4">
              <h3 class="font-bold text-lg">Add Pilot to Company</h3>
              <button
                type="button"
                phx-click="close_pilot_form"
                class="btn btn-sm btn-circle btn-ghost"
              >
                ✕
              </button>
            </div>

            <.live_component
              module={AcesWeb.CompanyLive.PilotFormComponent}
              id={:new_pilot}
              title="Add New Pilot"
              action={@pilot_form_action}
              pilot={%Aces.Companies.Pilot{}}
              company={@company}
              patch={~p"/companies/#{@company}/draft"}
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
              patch={~p"/companies/#{@company}/draft"}
            />
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end