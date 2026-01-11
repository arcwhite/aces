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
        {:ok,
         socket
         |> assign(:company, company)
         |> assign(:campaign, campaign)
         |> assign(:page_title, campaign.name)}
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
      <div class="grid gap-6 md:grid-cols-4 mb-8">
        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Difficulty</div>
          <div class="stat-value text-primary">{String.capitalize(@campaign.difficulty_level)}</div>
          <div class="stat-desc">
            PV: {Float.round(@campaign.pv_limit_modifier * 100)}% |
            Rewards: {Float.round(@campaign.reward_modifier * 100)}%
          </div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Warchest</div>
          <div class="stat-value text-secondary">{@campaign.warchest_balance} SP</div>
          <div class="stat-desc">Support Points available</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Sorties</div>
          <div class="stat-value text-info">{length(@campaign.sorties)}</div>
          <div class="stat-desc">Missions completed</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Experience Modifier</div>
          <div class="stat-value text-accent">{Float.round(@campaign.experience_modifier * 100)}%</div>
          <div class="stat-desc">Based on pilot skill</div>
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
                  <th>Mission #</th>
                  <th>Name</th>
                  <th>Status</th>
                  <th>PV Limit</th>
                  <th>Income</th>
                  <th>Expenses</th>
                  <th>Net</th>
                  <th>Started</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for sortie <- @campaign.sorties do %>
                  <tr>
                    <td class="font-mono">#{sortie.mission_number}</td>
                    <td class="font-semibold">{sortie.name || "Unnamed Mission"}</td>
                    <td>
                      <div class={[
                        "badge",
                        sortie.status == "setup" && "badge-neutral",
                        sortie.status == "in_progress" && "badge-warning", 
                        sortie.status == "completed" && "badge-success",
                        sortie.status == "failed" && "badge-error"
                      ]}>
                        {String.capitalize(sortie.status)}
                      </div>
                    </td>
                    <td>{sortie.pv_limit || 0} PV</td>
                    <td class="text-success">{sortie.total_income || 0} SP</td>
                    <td class="text-error">{sortie.total_expenses || 0} SP</td>
                    <td class={[
                      "font-semibold",
                      (sortie.net_earnings || 0) >= 0 && "text-success",
                      (sortie.net_earnings || 0) < 0 && "text-error"
                    ]}>
                      {sortie.net_earnings || 0} SP
                    </td>
                    <td>
                      <%= if sortie.started_at do %>
                        {Calendar.strftime(sortie.started_at, "%b %d, %Y")}
                      <% else %>
                        -
                      <% end %>
                    </td>
                    <td>
                      <.link 
                        navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{sortie.id}"}
                        class="btn btn-ghost btn-sm"
                      >
                        View
                      </.link>
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
        
        <%= if length(@campaign.pilot_campaign_stats) == 0 do %>
          <div class="alert alert-info">
            <span>No pilot stats available.</span>
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-zebra w-full">
              <thead>
                <tr>
                  <th>Pilot</th>
                  <th>SP Earned</th>
                  <th>Sorties</th>
                  <th>MVP Awards</th>
                </tr>
              </thead>
              <tbody>
                <%= for stats <- @campaign.pilot_campaign_stats do %>
                  <tr>
                    <td class="font-semibold">{stats.pilot.name}</td>
                    <td>{stats.sp_earned} SP</td>
                    <td>{stats.sorties_participated}</td>
                    <td>{stats.mvp_awards}</td>
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