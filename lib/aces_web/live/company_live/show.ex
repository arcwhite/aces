defmodule AcesWeb.CompanyLive.Show do
  use AcesWeb, :live_view

  alias Aces.Companies
  alias Aces.Companies.Authorization

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
       |> assign(:page_title, company.name)}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_unit", _params, socket) do
    # This will be implemented when we add unit management
    {:noreply, put_flash(socket, :info, "Unit management coming soon!")}
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

      <div class="grid gap-6 md:grid-cols-3 mb-8">
        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Total Units</div>
          <div class="stat-value text-primary">{@company.stats.unit_count}</div>
          <div class="stat-desc">In roster</div>
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
    </div>
    """
  end
end
