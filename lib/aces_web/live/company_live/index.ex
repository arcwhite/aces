defmodule AcesWeb.CompanyLive.Index do
  use AcesWeb, :live_view

  alias Aces.Companies
  alias Aces.Companies.Authorization

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    unless Authorization.can?(:list_companies, user, nil) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      companies = Companies.list_user_companies_with_stats(user)
      draft_companies = companies |> Enum.filter(&(&1.status == "draft"))
      active_companies = companies |> Enum.filter(&(&1.status == "active"))
      
      {:ok, assign(socket, 
        companies: companies, 
        draft_companies: draft_companies,
        active_companies: active_companies,
        page_title: "My Companies")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "My Companies")
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    company = Companies.get_company!(id)
    user = socket.assigns.current_scope.user

    if Authorization.can?(:delete_company, user, company) do
      {:ok, _} = Companies.delete_company(company)

      companies = Companies.list_user_companies_with_stats(user)
      draft_companies = companies |> Enum.filter(&(&1.status == "draft"))
      active_companies = companies |> Enum.filter(&(&1.status == "active"))

      {:noreply,
       socket
       |> put_flash(:info, "Company deleted successfully")
       |> assign(:companies, companies)
       |> assign(:draft_companies, draft_companies)
       |> assign(:active_companies, active_companies)}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to delete this company")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="flex justify-between items-center mb-8">
        <h1 class="text-4xl font-bold">My Mercenary Companies</h1>
        <.link
          navigate={~p"/companies/new"}
          class="btn btn-primary"
        >
          Create New Company
        </.link>
      </div>

      <%= if @companies == [] do %>
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
          <span>
            You don't have any companies yet. Create your first mercenary company to get started!
          </span>
        </div>
      <% else %>
        <!-- Draft Companies Section -->
        <%= if @draft_companies != [] do %>
          <div class="mb-8">
            <h2 class="text-2xl font-bold mb-4">Draft Companies</h2>
            <div class="alert alert-warning mb-4">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.856-.833-2.498 0L5.232 16.5c-.77.833.192 2.5 1.732 2.5z"></path>
              </svg>
              <span>These companies are still being set up. Complete your roster and finalize them to make them active.</span>
            </div>
            <div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
              <%= for company <- @draft_companies do %>
                <div class="card bg-base-100 shadow-xl border-2 border-warning">
                  <div class="card-body">
                    <div class="flex justify-between items-start mb-2">
                      <h2 class="card-title">{company.name}</h2>
                      <div class="badge badge-warning">DRAFT</div>
                    </div>

                    <%= if company.description do %>
                      <p class="text-sm opacity-70">{company.description}</p>
                    <% end %>

                    <div class="stats stats-vertical shadow mt-4">
                      <div class="stat">
                        <div class="stat-title">PV Used</div>
                        <div class="stat-value text-accent">{company.stats.pv_used}/{company.stats.pv_budget}</div>
                      </div>

                      <div class="stat">
                        <div class="stat-title">Units</div>
                        <div class="stat-value text-primary">{company.stats.unit_count}</div>
                      </div>

                      <div class="stat">
                        <div class="stat-title">Future Warchest</div>
                        <div class="stat-value text-secondary">{company.stats.warchest_balance + (company.stats.pv_remaining * 40)} SP</div>
                      </div>
                    </div>

                    <div class="card-actions justify-end mt-4">
                      <.link
                        navigate={~p"/companies/#{company}/draft"}
                        class="btn btn-warning btn-sm"
                      >
                        Continue Setup
                      </.link>

                      <button
                        type="button"
                        phx-click="delete"
                        phx-value-id={company.id}
                        data-confirm="Are you sure you want to delete this draft company? This action cannot be undone."
                        class="btn btn-ghost btn-sm text-error"
                      >
                        Delete
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
          
          <%= if @active_companies != [] do %>
            <div class="divider"></div>
          <% end %>
        <% end %>

        <!-- Active Companies Section -->
        <%= if @active_companies != [] do %>
          <div class="mb-8">
            <h2 class="text-2xl font-bold mb-4">Active Companies</h2>
            <div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
              <%= for company <- @active_companies do %>
                <div class="card bg-base-100 shadow-xl">
                  <div class="card-body">
                    <div class="flex justify-between items-start mb-2">
                      <h2 class="card-title">{company.name}</h2>
                      <div class="badge badge-success">ACTIVE</div>
                    </div>

                    <%= if company.description do %>
                      <p class="text-sm opacity-70">{company.description}</p>
                    <% end %>

                    <div class="stats stats-vertical shadow mt-4">
                      <div class="stat">
                        <div class="stat-title">Units</div>
                        <div class="stat-value text-primary">{company.stats.unit_count}</div>
                      </div>

                      <div class="stat">
                        <div class="stat-title">Warchest</div>
                        <div class="stat-value text-secondary">{company.stats.warchest_balance} SP</div>
                      </div>

                      <div class="stat">
                        <div class="stat-title">Last Modified</div>
                        <div class="stat-value text-sm">
                          {Calendar.strftime(company.stats.last_modified, "%b %d, %Y")}
                        </div>
                      </div>
                    </div>

                    <div class="card-actions justify-end mt-4">
                      <.link
                        navigate={~p"/companies/#{company}"}
                        class="btn btn-primary btn-sm"
                      >
                        View Details
                      </.link>

                      <button
                        type="button"
                        phx-click="delete"
                        phx-value-id={company.id}
                        data-confirm="Are you sure you want to delete this company? This action cannot be undone."
                        class="btn btn-ghost btn-sm text-error"
                      >
                        Delete
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
