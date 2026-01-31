defmodule AcesWeb.CampaignLive.Show do
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns, ChangesetHelpers}
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

        # Calculate overview data
        overview = Campaigns.calculate_campaign_overview(campaign)
        wounded_pilots = get_wounded_pilots(company)

        {:ok,
         socket
         |> assign(:company, company)
         |> assign(:campaign, campaign)
         |> assign(:pilot_performance, pilot_performance)
         |> assign(:overview, overview)
         |> assign(:wounded_pilots, wounded_pilots)
         |> assign(:active_tab, :overview)
         |> assign(:page_title, campaign.name)
         |> assign(:can_edit, Authorization.can?(:edit_company, user, company))
         |> assign(:can_purchase_units, Campaigns.can_purchase_units?(campaign))
         |> assign(:can_hire_pilots, Campaigns.can_hire_pilots?(campaign))
         |> assign(:show_unit_search, false)
         |> assign(:show_sell_modal, false)
         |> assign(:show_pilot_form, false)
         |> assign(:selling_unit, nil)
         |> assign(:unit_add_error, nil)}
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

  # Tab navigation handler
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  # Unit search modal handlers
  def handle_event("open_unit_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_unit_search, true)
     |> assign(:unit_add_error, nil)}
  end

  # Pilot hire modal handlers
  def handle_event("hire_pilot", _params, socket) do
    {:noreply, assign(socket, :show_pilot_form, true)}
  end

  def handle_event("close_pilot_form", _params, socket) do
    {:noreply, assign(socket, :show_pilot_form, false)}
  end

  # Unit selling handlers
  def handle_event("sell_unit", %{"unit_id" => unit_id_str}, socket) do
    unit_id = String.to_integer(unit_id_str)
    company = socket.assigns.company
    campaign = socket.assigns.campaign

    # Only allow selling on active campaigns
    if campaign.status != "active" do
      {:noreply, put_flash(socket, :error, "Cannot sell units: campaign is not active")}
    else
      case Enum.find(company.company_units, &(&1.id == unit_id)) do
        nil ->
          {:noreply, put_flash(socket, :error, "Unit not found")}

        unit ->
          if Campaigns.can_sell_unit?(unit) do
            {:noreply,
             socket
             |> assign(:show_sell_modal, true)
             |> assign(:selling_unit, unit)}
          else
            case Campaigns.get_unit_active_sortie(unit) do
              %{name: name, mission_number: number} ->
                {:noreply, put_flash(socket, :error, "Cannot sell: unit is deployed in Sortie #{number} (#{name})")}

              nil ->
                {:noreply, put_flash(socket, :error, "Cannot sell: unit is deployed in an active sortie")}
            end
          end
      end
    end
  end

  def handle_event("close_sell_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_sell_modal, false)
     |> assign(:selling_unit, nil)}
  end

  def handle_event("confirm_sell_unit", _params, socket) do
    selling_unit = socket.assigns.selling_unit
    campaign = socket.assigns.campaign
    user = socket.assigns.current_scope.user
    company = socket.assigns.company

    if Authorization.can?(:edit_company, user, company) do
      case Campaigns.sell_unit(selling_unit, campaign) do
        {:ok, sell_price} ->
          updated_campaign = Campaigns.get_campaign!(campaign.id)
          updated_company = Companies.get_company!(company.id)
          unit_name = selling_unit.custom_name ||
            Aces.Units.MasterUnit.display_name(selling_unit.master_unit)

          {:noreply,
           socket
           |> assign(:company, updated_company)
           |> assign(:campaign, updated_campaign)
           |> assign(:can_purchase_units, Campaigns.can_purchase_units?(updated_campaign))
           |> assign(:show_sell_modal, false)
           |> assign(:selling_unit, nil)
           |> put_flash(:info, "Sold #{unit_name} for #{sell_price} SP")}

        {:error, message} when is_binary(message) ->
          {:noreply,
           socket
           |> assign(:show_sell_modal, false)
           |> assign(:selling_unit, nil)
           |> put_flash(:error, message)}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(:show_sell_modal, false)
           |> assign(:selling_unit, nil)
           |> put_flash(:error, "Failed to sell unit: #{inspect(error)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to sell units")}
    end
  end

  @impl true
  def handle_info({AcesWeb.Components.UnitSearchModal, :close_modal}, socket) do
    {:noreply,
     socket
     |> assign(:show_unit_search, false)
     |> assign(:unit_add_error, nil)}
  end

  def handle_info({AcesWeb.Components.UnitSearchModal, {:unit_selected, mul_id}}, socket) do
    campaign = socket.assigns.campaign
    user = socket.assigns.current_scope.user

    if Authorization.can?(:edit_company, user, socket.assigns.company) do
      case Campaigns.purchase_unit_for_campaign(campaign, mul_id) do
        {:ok, _company_unit} ->
          updated_campaign = Campaigns.get_campaign!(campaign.id)
          updated_company = Companies.get_company!(socket.assigns.company.id)

          {:noreply,
           socket
           |> assign(:campaign, updated_campaign)
           |> assign(:company, updated_company)
           |> assign(:can_purchase_units, Campaigns.can_purchase_units?(updated_campaign))
           |> put_flash(:info, "Unit purchased successfully!")
           |> assign(:show_unit_search, false)}

        {:error, %Ecto.Changeset{} = changeset} ->
          error_message = ChangesetHelpers.format_errors(changeset)
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

  def handle_info({AcesWeb.CompanyLive.PilotFormComponent, {:pilot_hired, _pilot, updated_campaign}}, socket) do
    # Refresh company and campaign data after hiring
    updated_company = Companies.get_company!(socket.assigns.company.id)

    {:noreply,
     socket
     |> assign(:company, updated_company)
     |> assign(:campaign, updated_campaign)
     |> assign(:can_purchase_units, Campaigns.can_purchase_units?(updated_campaign))
     |> assign(:can_hire_pilots, Campaigns.can_hire_pilots?(updated_campaign))
     |> assign(:show_pilot_form, false)}
  end

  # Helper to get wounded pilots from company
  defp get_wounded_pilots(%{pilots: pilots}) when is_list(pilots) do
    Enum.filter(pilots, &(&1.status == "wounded"))
  end
  defp get_wounded_pilots(_), do: []

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

      <!-- Tab Navigation -->
      <.tab_navigation active_tab={@active_tab} />

      <!-- Tab Content -->
      <.tab_content
        active_tab={@active_tab}
        campaign={@campaign}
        company={@company}
        overview={@overview}
        wounded_pilots={@wounded_pilots}
        pilot_performance={@pilot_performance}
        can_edit={@can_edit}
        can_purchase_units={@can_purchase_units}
        can_hire_pilots={@can_hire_pilots}
      />

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
      <.live_component
        module={AcesWeb.Components.UnitSearchModal}
        id="unit-search"
        show={@show_unit_search}
        mode={:sp_purchase}
        budget={@campaign.warchest_balance}
        error={@unit_add_error}
      />

      <!-- Sell Unit Confirmation Modal -->
      <.sell_modal
        show={@show_sell_modal}
        selling_unit={@selling_unit}
      />

      <!-- Pilot Hire Modal -->
      <%= if @show_pilot_form do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-4xl">
            <div class="flex justify-between items-center mb-4">
              <button
                type="button"
                phx-click="close_pilot_form"
                class="btn btn-sm btn-circle btn-ghost absolute right-4 top-4"
              >
                ✕
              </button>
            </div>

            <.live_component
              module={AcesWeb.CompanyLive.PilotFormComponent}
              id={:hire_pilot}
              pilot={%Aces.Companies.Pilot{}}
              company={@company}
              campaign={@campaign}
              action={:hire}
              title="Hire New Pilot"
              patch={~p"/companies/#{@company}/campaigns/#{@campaign}"}
            />
          </div>
          <div class="modal-backdrop" phx-click="close_pilot_form"></div>
        </div>
      <% end %>
    </div>
    """
  end

  # Tab navigation component
  defp tab_navigation(assigns) do
    ~H"""
    <div role="tablist" class="tabs tabs-boxed mb-6">
      <button
        :for={{label, tab} <- [{"Overview", :overview}, {"Sorties", :sorties},
                               {"Units", :units}, {"Pilots", :pilots}, {"Timeline", :timeline}]}
        role="tab"
        class={["tab", @active_tab == tab && "tab-active"]}
        phx-click="set_tab"
        phx-value-tab={tab}
      >
        {label}
      </button>
    </div>
    """
  end

  # Tab content router
  defp tab_content(%{active_tab: :overview} = assigns), do: overview_tab(assigns)
  defp tab_content(%{active_tab: :sorties} = assigns), do: sorties_tab(assigns)
  defp tab_content(%{active_tab: :units} = assigns), do: units_tab(assigns)
  defp tab_content(%{active_tab: :pilots} = assigns), do: pilots_tab(assigns)
  defp tab_content(%{active_tab: :timeline} = assigns), do: timeline_tab(assigns)

  # Overview Tab
  defp overview_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Action Buttons -->
      <div class="flex flex-wrap gap-3">
        <%= if @campaign.status == "active" do %>
          <%= if @overview.has_active_sortie do %>
            <.link
              navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@overview.active_sortie.id}"}
              class="btn btn-primary"
            >
              Continue Sortie
            </.link>
          <% else %>
            <.link
              navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/new"}
              class="btn btn-primary"
            >
              Start New Sortie
            </.link>
          <% end %>

          <button
            type="button"
            phx-click="open_unit_search"
            class="btn btn-secondary"
            disabled={not @can_purchase_units}
            title={if @can_purchase_units, do: "Purchase new unit with SP", else: "Cannot purchase units while sortie is in progress"}
          >
            Purchase Units
          </button>

          <button
            type="button"
            phx-click="hire_pilot"
            class="btn btn-secondary"
            disabled={not @can_hire_pilots}
            title={cond do
              @overview.has_active_sortie -> "Cannot hire pilots while sortie is in progress"
              @campaign.warchest_balance < 150 -> "Insufficient SP (need 150 SP)"
              true -> "Hire new pilot for 150 SP"
            end}
          >
            Hire Pilot (150 SP)
          </button>
        <% end %>
      </div>

      <!-- Active Sortie Alert -->
      <%= if @overview.has_active_sortie do %>
        <div class="alert alert-warning">
          <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
          </svg>
          <div>
            <span class="font-semibold">Sortie in Progress:</span>
            Sortie #{@overview.active_sortie.mission_number} - {@overview.active_sortie.name || "Unnamed"}
            ({String.capitalize(@overview.active_sortie.status)})
          </div>
          <.link
            navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@overview.active_sortie.id}"}
            class="btn btn-sm"
          >
            View
          </.link>
        </div>
      <% end %>

      <div class="grid gap-6 md:grid-cols-2">
        <!-- Wounded Pilots Card -->
        <%= if length(@wounded_pilots) > 0 do %>
          <div class="card bg-base-200 shadow">
            <div class="card-body">
              <h3 class="card-title text-warning">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                </svg>
                Wounded Pilots ({length(@wounded_pilots)})
              </h3>
              <ul class="space-y-1">
                <%= for pilot <- @wounded_pilots do %>
                  <li class="flex items-center gap-2">
                    <span class="badge badge-warning badge-sm">Wounded</span>
                    <span>{pilot.name}</span>
                    <%= if pilot.callsign do %>
                      <span class="opacity-70">"{pilot.callsign}"</span>
                    <% end %>
                  </li>
                <% end %>
              </ul>
            </div>
          </div>
        <% end %>

        <!-- Campaign Finances Card -->
        <div class="card bg-base-200 shadow">
          <div class="card-body">
            <h3 class="card-title">Campaign Finances</h3>
            <div class="stats stats-vertical">
              <div class="stat py-2">
                <div class="stat-title text-xs">Total Income</div>
                <div class="stat-value text-success text-lg">{@overview.total_income} SP</div>
              </div>
              <div class="stat py-2">
                <div class="stat-title text-xs">Total Expenses</div>
                <div class="stat-value text-error text-lg">{@overview.total_expenses} SP</div>
              </div>
              <div class="stat py-2">
                <div class="stat-title text-xs">Net Profit</div>
                <div class={[
                  "stat-value text-lg",
                  @overview.net_profit >= 0 && "text-success",
                  @overview.net_profit < 0 && "text-error"
                ]}>
                  {@overview.net_profit} SP
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Losses Summary Card -->
        <%= if @overview.units_lost > 0 || @overview.pilots_killed > 0 || @overview.pilots_wounded > 0 do %>
          <div class="card bg-base-200 shadow">
            <div class="card-body">
              <h3 class="card-title text-error">Campaign Losses</h3>
              <div class="grid grid-cols-3 gap-4 text-center">
                <div>
                  <div class="text-2xl font-bold text-error">{@overview.units_lost}</div>
                  <div class="text-sm opacity-70">Units Lost</div>
                </div>
                <div>
                  <div class="text-2xl font-bold text-error">{@overview.pilots_killed}</div>
                  <div class="text-sm opacity-70">Pilots KIA</div>
                </div>
                <div>
                  <div class="text-2xl font-bold text-warning">{@overview.pilots_wounded}</div>
                  <div class="text-sm opacity-70">Pilots WIA</div>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <!-- Campaign Keywords -->
      <%= if @campaign.keywords && length(@campaign.keywords) > 0 do %>
        <div class="card bg-base-200 shadow">
          <div class="card-body">
            <h3 class="card-title">Campaign Keywords</h3>
            <div class="flex gap-2 flex-wrap">
              <%= for keyword <- @campaign.keywords do %>
                <div class="badge badge-outline">{keyword}</div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Sorties Tab
  defp sorties_tab(assigns) do
    ~H"""
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
    """
  end

  # Units Tab
  defp units_tab(assigns) do
    ~H"""
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
                <%= if @campaign.status == "active" && @can_edit do %>
                  <th>Actions</th>
                <% end %>
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
                  <%= if @campaign.status == "active" && @can_edit do %>
                    <td>
                      <button
                        class="btn btn-ghost btn-sm md:btn-xs text-error"
                        phx-click="sell_unit"
                        phx-value-unit_id={unit.id}
                        disabled={not @can_purchase_units}
                        title={if @can_purchase_units, do: "Sell for #{Aces.Units.MasterUnit.sell_price(unit.master_unit)} SP", else: "Cannot sell while sortie is in progress"}
                      >
                        Sell
                      </button>
                    </td>
                  <% end %>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  # Pilots Tab
  defp pilots_tab(assigns) do
    ~H"""
    <div class="space-y-8">
      <!-- Pilot Roster -->
      <div>
        <h2 class="text-2xl font-bold mb-4">Pilot Roster</h2>
        <%= if @company.pilots == [] do %>
          <div class="alert alert-info">
            <span>No pilots in your company.</span>
          </div>
        <% else %>
          <.pilot_cards pilots={@company.pilots} />
        <% end %>
      </div>

      <!-- Campaign Performance -->
      <div>
        <h2 class="text-2xl font-bold mb-4">Campaign Performance</h2>
        <p class="text-sm opacity-70 mb-4">SP earned and sorties participated in this campaign only.</p>

        <%= if Enum.empty?(@pilot_performance) do %>
          <div class="alert alert-info">
            <span>No campaign stats available yet. Complete sorties to see pilot performance.</span>
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-zebra w-full">
              <thead>
                <tr>
                  <th>Pilot</th>
                  <th class="text-right">Campaign SP</th>
                  <th class="text-center hidden sm:table-cell">Campaign Sorties</th>
                  <th class="text-center">Campaign MVP</th>
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
    </div>
    """
  end

  # Timeline Tab
  defp timeline_tab(assigns) do
    ~H"""
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
    """
  end

  # Sell modal component
  defp sell_modal(%{show: false} = assigns), do: ~H""
  defp sell_modal(%{selling_unit: nil} = assigns), do: ~H""
  defp sell_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg">Sell Unit</h3>

        <div class="py-4">
          <p class="mb-4">
            Are you sure you want to sell this unit?
          </p>

          <div class="card bg-base-200 p-4 mb-4">
            <div class="font-semibold text-lg">
              {Aces.Units.MasterUnit.display_name(@selling_unit.master_unit)}
            </div>
            <%= if @selling_unit.custom_name do %>
              <div class="text-sm opacity-70">{@selling_unit.custom_name}</div>
            <% end %>
            <div class="flex gap-2 mt-2">
              <div class="badge badge-outline">
                {String.replace(@selling_unit.master_unit.unit_type, "_", " ") |> String.capitalize()}
              </div>
              <%= if @selling_unit.master_unit.tonnage do %>
                <div class="badge badge-neutral">{@selling_unit.master_unit.tonnage}t</div>
              <% end %>
              <div class="badge badge-accent">{@selling_unit.master_unit.point_value} PV</div>
            </div>
          </div>

          <div class="alert alert-warning">
            <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
            </svg>
            <span>
              This action cannot be undone. The unit will be permanently removed from your roster.
            </span>
          </div>

          <div class="stat bg-success/20 rounded-lg mt-4">
            <div class="stat-title">You will receive</div>
            <div class="stat-value text-success">
              +{Aces.Units.MasterUnit.sell_price(@selling_unit.master_unit)} SP
            </div>
            <div class="stat-desc">Added to campaign warchest</div>
          </div>
        </div>

        <div class="modal-action">
          <button
            type="button"
            phx-click="close_sell_modal"
            class="btn"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="confirm_sell_unit"
            class="btn btn-error"
          >
            Sell Unit
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_sell_modal"></div>
    </div>
    """
  end
end
