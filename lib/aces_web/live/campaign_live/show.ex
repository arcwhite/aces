defmodule AcesWeb.CampaignLive.Show do
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
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
         |> assign(:can_edit, Authorization.can?(:edit_company, user, company))}
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
    </div>
    """
  end
end
