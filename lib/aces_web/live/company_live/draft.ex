defmodule AcesWeb.CompanyLive.Draft do
  use AcesWeb, :live_view

  alias Aces.Companies
  alias Aces.Companies.Authorization
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
         |> assign(:show_pilot_form, false)
         |> assign(:pilot_form_action, :new)}
      end
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_unit", _params, socket) do
    {:noreply, assign(socket, :show_unit_search, true) |> assign(:unit_add_error, nil)}
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
      case Companies.purchase_unit_for_company(company, mul_id) do
        {:ok, _company_unit} ->
          updated_company = Companies.get_company_with_stats!(company.id)

          {:noreply,
           socket
           |> assign(:company, updated_company)
           |> put_flash(:info, "Unit successfully added to roster!")
           |> assign(:show_unit_search, false)
           |> assign(:unit_add_error, nil)}

        # Handle validation errors from changesets
        {:error, %Ecto.Changeset{} = changeset} ->
          error_message = extract_changeset_error_message(changeset)
          {:noreply, assign(socket, :unit_add_error, error_message)}

        {:error, %{type: :unit_not_found, message: message}} ->
          {:noreply, assign(socket, :unit_add_error, message)}

        {:error, %{type: :unit_lookup_failed, message: message}} ->
          {:noreply, assign(socket, :unit_add_error, "Failed to add unit: #{message}")}
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

  def handle_event("remove_unit", %{"unit_id" => unit_id_str}, socket) do
    unit_id = String.to_integer(unit_id_str)
    company = socket.assigns.company
    user = socket.assigns.current_scope.user

    if Authorization.can?(:edit_company, user, company) do
      company_unit = Enum.find(company.company_units, &(&1.id == unit_id))
      
      if company_unit do
        case Companies.remove_unit_from_company(company_unit) do
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
        case Companies.delete_pilot(pilot) do
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

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to finalize company: #{reason}")}
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

  def handle_info({:perform_search, search_term}, socket) do
    if socket.assigns.unit_search_term == search_term do
      try do
        search_results = Units.search_units(search_term, unit_type: "battlemech")

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

  # Extract a user-friendly error message from changeset
  defp extract_changeset_error_message(%Ecto.Changeset{} = changeset) do
    # Look for our custom validation errors first
    case Enum.find(changeset.errors, fn {field, _} -> field == :master_unit_id end) do
      {_, {message, _}} -> message
      nil ->
        # Check for company errors
        case Enum.find(changeset.errors, fn {field, _} -> field == :company_id end) do
          {_, {message, _}} -> message
          nil ->
            # Fallback for other errors
            changeset.errors
            |> Enum.map(fn {_field, {msg, _}} -> msg end)
            |> Enum.join(", ")
        end
    end
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
                  <th>Unit Name</th>
                  <th>Type</th>
                  <th>Cost (SP)</th>
                  <th>PV</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for unit <- @company.company_units do %>
                  <tr>
                    <td>
                      <%= if unit.master_unit do %>
                        {unit.master_unit.name} {unit.master_unit.variant}
                      <% else %>
                        Unknown Unit
                      <% end %>
                    </td>
                    <td>
                      <div class="badge badge-outline">
                        {if unit.master_unit, do: unit.master_unit.unit_type, else: "N/A"}
                      </div>
                    </td>
                    <td>{unit.purchase_cost_sp} SP</td>
                    <td>{unit.master_unit.point_value}</td>
                    <td>
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
    </div>
    """
  end
end