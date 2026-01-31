defmodule AcesWeb.CampaignLive.Show do
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns, Units}
  alias Aces.Companies.Authorization

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(%{"company_id" => company_id, "id" => campaign_id}, _session, socket) do
    company = Companies.get_company!(company_id)
    campaign = Campaigns.get_campaign!(campaign_id)
    user = socket.assigns.current_scope.user

    unless Authorization.can?(:view_company, user, company) do
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view this company")
       |> redirect(to: ~p"/companies")}
    else
      # Verify campaign belongs to company
      if campaign.company_id != company.id do
        {:ok,
         socket
         |> put_flash(:error, "Campaign not found")
         |> redirect(to: ~p"/companies/#{company_id}")}
      else
        # Calculate pilot performance from actual sortie data
        pilot_performance = Campaigns.calculate_pilot_performance(campaign)

        {:ok,
         socket
         |> assign(:company, company)
         |> assign(:campaign, campaign)
         |> assign(:pilot_performance, pilot_performance)
         |> assign(:page_title, campaign.name)
         |> assign(:can_edit, Authorization.can?(:edit_company, user, company))
         |> assign(:can_purchase_units, Campaigns.can_purchase_units?(campaign))
         # Unit search modal state
         |> assign(:show_unit_search, false)
         |> assign(:unit_search_term, "")
         |> assign(:search_results, [])
         |> assign(:search_loading, false)
         |> assign(:unit_add_error, nil)
         |> assign(:search_filter_eras, ["ilclan", "dark_age"])
         |> assign(:search_filter_faction, "mercenary")
         |> assign(:search_filter_type, nil)}
      end
    end
  end

  @impl true
  def handle_event("complete_campaign", %{"outcome" => outcome}, socket) do
    campaign = socket.assigns.campaign
    user = socket.assigns.current_scope.user

    if Authorization.can?(:edit_company, user, socket.assigns.company) do
      case Campaigns.complete_campaign(campaign, outcome) do
        {:ok, updated_campaign} ->
          {:noreply,
           socket
           |> assign(:campaign, updated_campaign)
           |> assign(:can_purchase_units, Campaigns.can_purchase_units?(updated_campaign))
           |> put_flash(:info, "Campaign #{outcome} successfully!")}

        {:error, changeset} ->
          error_message =
            changeset.errors
            |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
            |> Enum.join(", ")

          {:noreply,
           socket
           |> put_flash(:error, "Failed to complete campaign: #{error_message}")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to complete this campaign")}
    end
  end

  # Unit search modal handlers
  def handle_event("open_unit_search", _params, socket) do
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

  def handle_event("purchase_unit", %{"mul_id" => mul_id_str}, socket) do
    mul_id = String.to_integer(mul_id_str)
    campaign = socket.assigns.campaign
    user = socket.assigns.current_scope.user

    if Authorization.can?(:edit_company, user, socket.assigns.company) do
      case Campaigns.purchase_unit_for_campaign(campaign, mul_id) do
        {:ok, _company_unit} ->
          # Reload campaign and company to get updated data
          updated_campaign = Campaigns.get_campaign!(campaign.id)
          updated_company = Companies.get_company!(socket.assigns.company.id)

          {:noreply,
           socket
           |> assign(:campaign, updated_campaign)
           |> assign(:company, updated_company)
           |> assign(:can_purchase_units, Campaigns.can_purchase_units?(updated_campaign))
           |> put_flash(:info, "Unit purchased successfully!")
           |> assign(:show_unit_search, false)
           |> assign(:unit_search_term, "")
           |> assign(:search_results, [])}

        {:error, %Ecto.Changeset{} = changeset} ->
          error_message = format_changeset_errors(changeset)
          {:noreply, assign(socket, :unit_add_error, error_message)}

        {:error, message} when is_binary(message) ->
          {:noreply, assign(socket, :unit_add_error, message)}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to purchase units")}
    end
  end

  @impl true
  def handle_info({:perform_search, search_term}, socket) do
    # Only perform search if the search term hasn't changed
    if socket.assigns.unit_search_term == search_term do
      socket = perform_unit_search(socket, search_term)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Helper to run search immediately when filters change
  defp maybe_run_search(socket) do
    perform_unit_search(socket, socket.assigns.unit_search_term)
  end

  # Centralized search logic using the Units context
  defp perform_unit_search(socket, search_term) do
    filters = %{
      eras: socket.assigns.search_filter_eras,
      faction: socket.assigns.search_filter_faction,
      type: socket.assigns.search_filter_type
    }

    case Units.search_units_for_company(search_term, filters) do
      {:ok, results} ->
        socket
        |> assign(:search_results, results)
        |> assign(:search_loading, false)

      {:error, :term_too_short} ->
        socket
        |> assign(:search_results, [])
        |> assign(:search_loading, false)

      {:error, _reason} ->
        socket
        |> assign(:search_results, [])
        |> assign(:search_loading, false)
        |> put_flash(:error, "Search failed. Please try again.")
    end
  end

  defp format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end

  # Calculate SP cost for a unit (PV × 40)
  defp unit_sp_cost(unit) do
    (unit.point_value || 0) * 40
  end

  # Check if user can afford unit
  defp can_afford_unit?(unit, campaign) do
    unit_sp_cost(unit) <= campaign.warchest_balance
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <.link navigate={~p"/companies/#{@company.id}"} class="btn btn-ghost btn-sm">
            ← Back to {@company.name}
          </.link>
        </div>

        <div class="flex justify-between items-start mb-4">
          <div>
            <h1 class="text-4xl font-bold mb-2">{@campaign.name}</h1>
            <%= if @campaign.description do %>
              <p class="text-lg opacity-70">{@campaign.description}</p>
            <% end %>
          </div>

          <div class="flex items-center gap-2">
            <div class={[
              "badge badge-lg",
              @campaign.status == "active" && "badge-success",
              @campaign.status == "completed" && "badge-info",
              @campaign.status == "failed" && "badge-error"
            ]}>
              {String.capitalize(@campaign.status)}
            </div>

            <%= if @campaign.status == "active" do %>
              <div class="dropdown dropdown-end">
                <div tabindex="0" role="button" class="btn btn-primary btn-sm">
                  Complete Campaign
                </div>
                <ul tabindex="0" class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-52">
                  <li>
                    <a
                      phx-click="complete_campaign"
                      phx-value-outcome="completed"
                      data-confirm="Mark this campaign as completed?"
                    >
                      Mark Completed
                    </a>
                  </li>
                  <li>
                    <a
                      phx-click="complete_campaign"
                      phx-value-outcome="failed"
                      data-confirm="Mark this campaign as failed?"
                    >
                      Mark Failed
                    </a>
                  </li>
                </ul>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <!-- Campaign Stats -->
      <div class="grid grid-cols-2 gap-3 md:gap-6 lg:grid-cols-4 mb-8">
        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4">
          <div class="stat-title text-xs md:text-sm">Difficulty</div>
          <div class="stat-value text-lg md:text-3xl text-primary">{String.capitalize(@campaign.difficulty_level)}</div>
          <div class="stat-desc text-xs hidden md:block">
            PV: {Float.round(@campaign.pv_limit_modifier * 100)}% |
            Rewards: {Float.round(@campaign.reward_modifier * 100)}%
          </div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4">
          <div class="stat-title text-xs md:text-sm">Warchest</div>
          <div class="stat-value text-xl md:text-3xl text-secondary">
            <span class="whitespace-nowrap">{@campaign.warchest_balance} SP</span>
          </div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4">
          <div class="stat-title text-xs md:text-sm">Sorties</div>
          <div class="stat-value text-xl md:text-3xl text-info">{length(@campaign.sorties)}</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4">
          <div class="stat-title text-xs md:text-sm">XP Modifier</div>
          <div class="stat-value text-xl md:text-3xl text-accent">
            <span class="whitespace-nowrap">{Float.round(@campaign.experience_modifier * 100)}%</span>
          </div>
        </div>
      </div>

      <!-- Campaign Keywords -->
      <%= if @campaign.keywords && length(@campaign.keywords) > 0 do %>
        <div class="mb-6">
          <h3 class="text-xl font-semibold mb-2">Campaign Keywords</h3>
          <div class="flex gap-2 flex-wrap">
            <%= for keyword <- @campaign.keywords do %>
              <div class="badge badge-outline">{keyword}</div>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Unit Roster Section -->
      <div class="mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-2xl font-bold">Unit Roster</h2>
          <%= if @can_edit do %>
            <button
              type="button"
              phx-click="open_unit_search"
              class="btn btn-primary"
              disabled={not @can_purchase_units}
              title={if @can_purchase_units, do: "Purchase new unit with SP", else: "Cannot purchase units while sortie is in progress"}
            >
              Purchase Units
            </button>
          <% end %>
        </div>

        <%= if not @can_purchase_units and @campaign.status == "active" do %>
          <div class="alert alert-warning mb-4">
            <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
            </svg>
            <span>Unit purchases are disabled while a sortie is in progress.</span>
          </div>
        <% end %>

        <%= if @company.company_units == [] do %>
          <div class="alert alert-info">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
            </svg>
            <span>No units in roster. Purchase units to expand your force!</span>
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
                  <th class="hidden md:table-cell">PV</th>
                  <th class="hidden lg:table-cell">SP Cost</th>
                </tr>
              </thead>
              <tbody>
                <%= for unit <- @company.company_units do %>
                  <tr>
                    <td>
                      <%= if unit.master_unit do %>
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
                        unit.status == "destroyed" && "badge-error",
                        unit.status == "salvaged" && "badge-info"
                      ]}>
                        {String.capitalize(unit.status)}
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
                      <%= if unit.master_unit do %>
                        <span class="badge badge-accent badge-sm">{unit.master_unit.point_value || 0} PV</span>
                      <% end %>
                    </td>
                    <td class="hidden lg:table-cell">
                      <%= if unit.purchase_cost_sp && unit.purchase_cost_sp > 0 do %>
                        <span class="text-sm font-mono">{unit.purchase_cost_sp} SP</span>
                      <% else %>
                        <span class="text-gray-500 text-sm">-</span>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>

      <!-- Sortie History -->
      <div class="mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-2xl font-bold">Sortie History</h2>
          <%= if @campaign.status == "active" do %>
            <.link
              navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/new"}
              class="btn btn-primary"
            >
              Start New Sortie
            </.link>
          <% end %>
        </div>

        <%= if length(@campaign.sorties) == 0 do %>
          <div class="alert alert-info">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
            </svg>
            <span>No sorties completed yet. <%= if @campaign.status == "active", do: "Start your first mission!", else: "This campaign had no sorties." %></span>
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-zebra w-full">
              <thead>
                <tr>
                  <th>Mission</th>
                  <th>Status</th>
                  <th class="hidden sm:table-cell">PV</th>
                  <th class="hidden md:table-cell">Income</th>
                  <th class="hidden md:table-cell">Expenses</th>
                  <th class="hidden sm:table-cell">Net</th>
                  <th class="hidden lg:table-cell">Started</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for sortie <- @campaign.sorties do %>
                  <tr>
                    <td>
                      <div class="font-mono text-xs md:text-sm">#{sortie.mission_number}</div>
                      <div class="font-semibold text-sm">{sortie.name || "Unnamed"}</div>
                    </td>
                    <td>
                      <div class={[
                        "badge badge-xs md:badge-md whitespace-nowrap",
                        sortie.status == "setup" && "badge-neutral",
                        sortie.status == "in_progress" && "badge-warning",
                        sortie.status == "completed" && "badge-success",
                        sortie.status == "failed" && "badge-error"
                      ]}>
                        {String.capitalize(sortie.status)}
                      </div>
                    </td>
                    <td class="hidden sm:table-cell whitespace-nowrap">{sortie.pv_limit || 0} PV</td>
                    <td class="hidden md:table-cell text-success">{sortie.total_income || 0} SP</td>
                    <td class="hidden md:table-cell text-error">{sortie.total_expenses || 0} SP</td>
                    <td class={[
                      "hidden sm:table-cell font-semibold whitespace-nowrap",
                      (sortie.net_earnings || 0) >= 0 && "text-success",
                      (sortie.net_earnings || 0) < 0 && "text-error"
                    ]}>
                      {sortie.net_earnings || 0} SP
                    </td>
                    <td class="hidden lg:table-cell">
                      <%= if sortie.started_at do %>
                        {Calendar.strftime(sortie.started_at, "%b %d, %Y")}
                      <% else %>
                        -
                      <% end %>
                    </td>
                    <td>
                      <div class="flex flex-col sm:flex-row gap-1">
                        <.link
                          navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{sortie.id}"}
                          class="btn btn-ghost btn-sm md:btn-xs"
                        >
                          View
                        </.link>
                        <%= if sortie.status == "setup" and @can_edit do %>
                          <.link
                            navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{sortie.id}/edit"}
                            class="btn btn-outline btn-sm md:btn-xs"
                          >
                            Edit
                          </.link>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>

      <!-- Campaign Events -->
      <div class="mb-8">
        <h2 class="text-2xl font-bold mb-4">Campaign Timeline</h2>

        <%= if length(@campaign.campaign_events) == 0 do %>
          <div class="alert alert-info">
            <span>No events recorded yet.</span>
          </div>
        <% else %>
          <div class="space-y-4">
            <%= for event <- @campaign.campaign_events do %>
              <div class="card bg-base-100 shadow">
                <div class="card-body py-4">
                  <div class="flex justify-between items-start">
                    <div>
                      <h4 class="font-semibold">{event.description}</h4>
                      <div class="flex gap-2 mt-1">
                        <div class="badge badge-outline badge-sm">{String.replace(event.event_type, "_", " ") |> String.capitalize()}</div>
                        <div class="text-sm text-gray-500">
                          {Calendar.strftime(event.occurred_at, "%b %d, %Y at %I:%M %p")}
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Pilot Campaign Stats -->
      <div class="mb-8">
        <h2 class="text-2xl font-bold mb-4">Pilot Performance</h2>

        <%= if Enum.empty?(@pilot_performance) do %>
          <div class="alert alert-info">
            <span>No pilot stats available. Complete sorties to see pilot performance.</span>
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-zebra w-full">
              <thead>
                <tr>
                  <th>Pilot</th>
                  <th class="text-right">SP Earned</th>
                  <th class="text-center hidden sm:table-cell">Sorties</th>
                  <th class="text-center">MVP</th>
                </tr>
              </thead>
              <tbody>
                <%= for stats <- @pilot_performance do %>
                  <tr>
                    <td>
                      <div class="font-semibold">{stats.pilot.name}</div>
                      <%= if stats.pilot.callsign do %>
                        <div class="text-sm opacity-70 hidden sm:block">"{stats.pilot.callsign}"</div>
                      <% end %>
                    </td>
                    <td class="text-right font-mono whitespace-nowrap">{stats.sp_earned} SP</td>
                    <td class="text-center hidden sm:table-cell">{stats.sorties_participated}</td>
                    <td class="text-center">
                      <%= if stats.mvp_awards > 0 do %>
                        <span class="badge badge-warning badge-sm md:badge-md">{stats.mvp_awards}</span>
                      <% else %>
                        <span class="opacity-50">0</span>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>

      <!-- Campaign Dates -->
      <div class="text-sm text-gray-600 mt-8 border-t pt-4">
        <div class="flex justify-between">
          <div>
            Started: {Calendar.strftime(@campaign.started_at, "%B %d, %Y at %I:%M %p")}
          </div>
          <%= if @campaign.completed_at do %>
            <div>
              Completed: {Calendar.strftime(@campaign.completed_at, "%B %d, %Y at %I:%M %p")}
            </div>
          <% end %>
        </div>
      </div>

      <!-- Unit Search Modal -->
      <%= if @show_unit_search do %>
        <div class="modal modal-open">
          <div class="modal-box w-11/12 max-w-4xl">
            <div class="flex justify-between items-center mb-4">
              <h3 class="font-bold text-lg">Purchase Unit</h3>
              <button
                type="button"
                phx-click="close_unit_search"
                class="btn btn-sm btn-circle btn-ghost"
              >
                ✕
              </button>
            </div>

            <div class="mb-4">
              <div class="alert alert-info mb-4">
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <div>
                  <div class="font-semibold">Warchest: {@campaign.warchest_balance} SP</div>
                  <div class="text-sm">Unit cost = PV × 40 SP</div>
                </div>
              </div>

              <%= if @unit_add_error do %>
                <div class="alert alert-error mb-4">
                  <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                  <span>{@unit_add_error}</span>
                </div>
              <% end %>

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
                    </select>
                  </form>
                </div>
              </div>
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
                                <div class="badge badge-secondary font-semibold">{unit_sp_cost(unit)} SP</div>
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
                              <%= if can_afford_unit?(unit, @campaign) do %>
                                <button
                                  type="button"
                                  phx-click="purchase_unit"
                                  phx-value-mul_id={unit.mul_id}
                                  class="btn btn-primary btn-sm"
                                >
                                  Purchase ({unit_sp_cost(unit)} SP)
                                </button>
                              <% else %>
                                <button
                                  type="button"
                                  disabled
                                  class="btn btn-disabled btn-sm"
                                  title="Insufficient SP in warchest"
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
                      <p class="text-gray-600">Search for units to purchase for your company</p>
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
