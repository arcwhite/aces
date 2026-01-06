defmodule AcesWeb.CompanyLive.Show do
  use AcesWeb, :live_view

  alias Aces.Companies
  alias Aces.Companies.Authorization
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
      {:ok,
       socket
       |> assign(:company, company)
       |> assign(:page_title, company.name)
       |> assign(:show_unit_search, false)
       |> assign(:unit_search_term, "")
       |> assign(:search_results, [])
       |> assign(:search_loading, false)}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_unit", _params, socket) do
    {:noreply, assign(socket, :show_unit_search, true)}
  end

  def handle_event("close_unit_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_unit_search, false)
     |> assign(:unit_search_term, "")
     |> assign(:search_results, [])
     |> assign(:search_loading, false)}
  end

  def handle_event("search_units", %{"search" => search_term}, socket) do
    search_term = String.trim(search_term)

    socket =
      if String.length(search_term) >= 2 do
        socket
        |> assign(:unit_search_term, search_term)
        |> assign(:search_loading, true)

        # Perform search asynchronously
        send(self(), {:perform_search, search_term})
        socket
      else
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
      case Companies.purchase_unit_for_company(company, mul_id) do
        {:ok, _company_unit} ->
          # Reload the company with updated stats
          updated_company = Companies.get_company_with_stats!(company.id)
          
          {:noreply,
           socket
           |> assign(:company, updated_company)
           |> put_flash(:info, "Unit successfully added to roster!")
           |> assign(:show_unit_search, false)}

        {:error, %{type: :insufficient_pv_budget, message: message, required_pv: required, available_pv: available, unit_name: unit_name}} ->
          {:noreply,
           socket
           |> put_flash(:error, "Cannot add #{unit_name}: #{message}. Need #{required} PV, but only #{available} PV remaining.")}

        {:error, %{type: :unit_not_found, message: message}} ->
          {:noreply,
           socket
           |> put_flash(:error, message)}

        {:error, %{type: :unit_lookup_failed, message: message}} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to add unit: #{message}")}

        {:error, changeset} ->
          # Handle validation errors
          error_message = 
            changeset.errors
            |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
            |> Enum.join(", ")
          
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
  def handle_info({:perform_search, search_term}, socket) do
    # Only perform search if the search term hasn't changed
    if socket.assigns.unit_search_term == search_term do
      search_results = Units.search_units(search_term, unit_type: "battlemech")

      {:noreply,
       socket
       |> assign(:search_results, search_results)
       |> assign(:search_loading, false)}
    else
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

      <div class="grid gap-6 md:grid-cols-4 mb-8">
        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Total Units</div>
          <div class="stat-value text-primary">{@company.stats.unit_count}</div>
          <div class="stat-desc">In roster</div>
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
          <h2 class="text-2xl font-bold">Unit Roster</h2>
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
            <span>No units in roster yet. Add your first unit to get started!</span>
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-zebra w-full">
              <thead>
                <tr>
                  <th>Unit Name</th>
                  <th>Type</th>
                  <th>Custom Name</th>
                  <th>Status</th>
                  <th>Cost (SP)</th>
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
                    <td>{unit.purchase_cost_sp} SP</td>
                    <td>
                      <button class="btn btn-ghost btn-xs">Edit</button>
                      <button class="btn btn-ghost btn-xs text-error">Remove</button>
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
                placeholder="Search for units (e.g. Atlas, Timber Wolf, Locust...)"
                class="input input-bordered w-full"
                value={@unit_search_term}
                phx-keyup="search_units"
                phx-value-search={@unit_search_term}
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
    </div>
    """
  end
end
