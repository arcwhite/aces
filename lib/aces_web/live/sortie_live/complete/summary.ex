defmodule AcesWeb.SortieLive.Complete.Summary do
  @moduledoc """
  Step 5 of sortie completion wizard: Summary and warchest update.
  Also serves as the read-only view for completed sorties.
  """
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
  alias Aces.Companies.Authorization

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(%{"company_id" => company_id, "campaign_id" => campaign_id, "id" => sortie_id}, _session, socket) do
    company = Companies.get_company!(company_id)
    campaign = Campaigns.get_campaign!(campaign_id)
    sortie = Campaigns.get_sortie!(sortie_id)
    user = socket.assigns.current_scope.user

    with :ok <- authorize_access(user, company, sortie),
         :ok <- validate_sortie_belongs_to_campaign(sortie, campaign, company),
         :ok <- validate_sortie_status(sortie) do
      # Check if this is a read-only view (completed) or finalization
      is_completed = sortie.status == "completed"

      {:ok,
       socket
       |> assign(:company, company)
       |> assign(:campaign, campaign)
       |> assign(:sortie, sortie)
       |> assign(:is_completed, is_completed)
       |> assign(:can_edit, Authorization.can?(:edit_company, user, company))
       |> assign(:page_title, if(is_completed, do: "Sortie Summary", else: "Complete Sortie: Summary"))}
    else
      {:error, message, redirect_path} ->
        {:ok,
         socket
         |> put_flash(:error, message)
         |> push_navigate(to: redirect_path)}
    end
  end

  defp authorize_access(user, company, sortie) do
    # For completed sorties, view permission is enough
    # For finalizing, edit permission is required
    has_permission =
      if sortie.status == "completed" do
        Authorization.can?(:view_company, user, company)
      else
        Authorization.can?(:edit_company, user, company)
      end

    if has_permission do
      :ok
    else
      {:error, "You don't have permission to view this sortie",
       ~p"/companies/#{company.id}"}
    end
  end

  defp validate_sortie_belongs_to_campaign(sortie, campaign, company) do
    if sortie.campaign_id == campaign.id and campaign.company_id == company.id do
      :ok
    else
      {:error, "Sortie not found",
       ~p"/companies/#{company.id}/campaigns/#{campaign.id}"}
    end
  end

  defp validate_sortie_status(sortie) do
    cond do
      sortie.status == "completed" ->
        :ok

      sortie.status == "finalizing" and sortie.finalization_step == "summary" ->
        :ok

      sortie.status == "finalizing" ->
        {:error, "Please complete the previous step first",
         ~p"/companies/#{sortie.campaign.company_id}/campaigns/#{sortie.campaign_id}/sorties/#{sortie.id}/complete/#{sortie.finalization_step}"}

      true ->
        {:error, "Sortie is not ready for summary",
         ~p"/companies/#{sortie.campaign.company_id}/campaigns/#{sortie.campaign_id}/sorties/#{sortie.id}"}
    end
  end

  @impl true
  def handle_event("complete_sortie", _params, socket) do
    sortie = socket.assigns.sortie
    campaign = socket.assigns.campaign

    # Calculate warchest addition (net earnings minus pilot pay is already in net_earnings)
    warchest_addition = sortie.net_earnings || 0

    # Update campaign warchest
    new_warchest = (campaign.warchest_balance || 0) + warchest_addition

    {:ok, _campaign} =
      campaign
      |> Ecto.Changeset.change(%{warchest_balance: new_warchest})
      |> Aces.Repo.update()

    # Mark sortie as completed
    {:ok, _sortie} =
      sortie
      |> Ecto.Changeset.change(%{
        status: "completed",
        was_successful: true,
        completed_at: DateTime.truncate(DateTime.utc_now(), :second),
        finalization_step: nil
      })
      |> Aces.Repo.update()

    # Heal pilots who were wounded in PREVIOUS sorties
    heal_previously_wounded_pilots(socket.assigns.company, sortie)

    {:noreply,
     socket
     |> put_flash(:info, "Sortie completed! #{warchest_addition} SP added to warchest.")
     |> push_navigate(to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{campaign.id}")}
  end

  defp heal_previously_wounded_pilots(company, current_sortie) do
    # Get pilots who are wounded but NOT wounded in this sortie
    wounded_in_sortie =
      current_sortie.deployments
      |> Enum.filter(&(&1.pilot_casualty == "wounded" && &1.pilot_id))
      |> Enum.map(& &1.pilot_id)
      |> MapSet.new()

    company
    |> Companies.list_pilots()
    |> Enum.filter(&(&1.status == "wounded" and not MapSet.member?(wounded_in_sortie, &1.id)))
    |> Enum.each(fn pilot ->
      pilot
      |> Ecto.Changeset.change(%{status: "active"})
      |> Aces.Repo.update()
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-4xl">
      <!-- Header -->
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <%= if @is_completed do %>
            <.link
              navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}"}
              class="btn btn-ghost btn-sm"
            >
              ← Back to Campaign
            </.link>
          <% else %>
            <.link
              navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/pilots"}
              class="btn btn-ghost btn-sm"
            >
              ← Back to Pilot SP
            </.link>
          <% end %>
        </div>

        <div class="flex justify-between items-start">
          <div>
            <h1 class="text-3xl font-bold mb-2">
              <%= if @is_completed do %>
                Sortie Summary
              <% else %>
                Complete Sortie: Summary
              <% end %>
            </h1>
            <p class="text-lg opacity-70">
              Sortie #{@sortie.mission_number}: {@sortie.name}
            </p>
          </div>

          <div class={[
            "badge badge-lg",
            if(@sortie.was_successful, do: "badge-success", else: "badge-error")
          ]}>
            <%= if @sortie.was_successful, do: "Victory", else: "Defeat" %>
          </div>
        </div>

        <!-- Progress Steps (only show when finalizing) -->
        <%= unless @is_completed do %>
          <div class="mt-6">
            <ul class="steps steps-horizontal w-full">
              <li class="step step-primary">Victory Details</li>
              <li class="step step-primary">Unit Status</li>
              <li class="step step-primary">Costs</li>
              <li class="step step-primary">Pilot SP</li>
              <li class="step step-primary">Summary</li>
            </ul>
          </div>
        <% end %>
      </div>

      <!-- Mission Summary -->
      <div class="card bg-base-200 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title">Mission Details</h2>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <div class="text-sm opacity-70">Started</div>
              <div class="font-semibold">
                {Calendar.strftime(@sortie.started_at, "%b %d, %Y")}
              </div>
            </div>
            <%= if @sortie.completed_at do %>
              <div>
                <div class="text-sm opacity-70">Completed</div>
                <div class="font-semibold">
                  {Calendar.strftime(@sortie.completed_at, "%b %d, %Y")}
                </div>
              </div>
            <% end %>
            <div>
              <div class="text-sm opacity-70">Force Commander</div>
              <div class="font-semibold">
                <%= if @sortie.force_commander do %>
                  {@sortie.force_commander.name}
                <% else %>
                  —
                <% end %>
              </div>
            </div>
            <div>
              <div class="text-sm opacity-70">MVP</div>
              <div class="font-semibold">
                <%= if @sortie.mvp_pilot do %>
                  {@sortie.mvp_pilot.name}
                <% else %>
                  —
                <% end %>
              </div>
            </div>
          </div>

          <%= if @sortie.keywords_gained && length(@sortie.keywords_gained) > 0 do %>
            <div class="mt-4">
              <div class="text-sm opacity-70 mb-2">Keywords Earned</div>
              <div class="flex flex-wrap gap-2">
                <%= for keyword <- @sortie.keywords_gained do %>
                  <span class="badge badge-primary">{keyword}</span>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Financial Summary -->
      <div class="card bg-base-200 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title">Financial Summary</h2>
          <div class="space-y-2">
            <div class="flex justify-between">
              <span>Primary Objective Income:</span>
              <span class="font-mono">{@sortie.primary_objective_income || 0} SP</span>
            </div>
            <div class="flex justify-between">
              <span>Secondary Objectives Income:</span>
              <span class="font-mono">{@sortie.secondary_objectives_income || 0} SP</span>
            </div>
            <div class="flex justify-between">
              <span>Waypoint Adjustments:</span>
              <span class="font-mono">{@sortie.waypoints_income || 0} SP</span>
            </div>
            <%= if @sortie.recon_total_cost && @sortie.recon_total_cost > 0 do %>
              <div class="flex justify-between text-warning">
                <span>Reconnaissance Costs:</span>
                <span class="font-mono">-{@sortie.recon_total_cost} SP</span>
              </div>
            <% end %>
            <div class="flex justify-between">
              <span>
                Difficulty Modifier ({String.capitalize(@campaign.difficulty_level)}):
              </span>
              <span class="font-mono">{format_modifier(@campaign.reward_modifier)}</span>
            </div>
            <div class="divider my-1"></div>
            <div class="flex justify-between font-bold">
              <span>Adjusted Income:</span>
              <span class="font-mono text-success">{@sortie.total_income || 0} SP</span>
            </div>
            <div class="flex justify-between text-error">
              <span>Total Expenses:</span>
              <span class="font-mono">-{@sortie.total_expenses || 0} SP</span>
            </div>
            <div class="divider my-1"></div>
            <div class="flex justify-between text-lg font-bold">
              <span>Net Earnings:</span>
              <span class={[
                "font-mono",
                if((@sortie.net_earnings || 0) >= 0, do: "text-success", else: "text-error")
              ]}>
                {@sortie.net_earnings || 0} SP
              </span>
            </div>
          </div>
        </div>
      </div>

      <!-- Unit Status Summary -->
      <div class="card bg-base-200 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title">Unit Status</h2>
          <div class="overflow-x-auto">
            <table class="table table-sm w-full">
              <thead>
                <tr>
                  <th>Unit</th>
                  <th>Damage</th>
                  <th>Crew</th>
                  <th class="text-right">Repair Cost</th>
                </tr>
              </thead>
              <tbody>
                <%= for deployment <- @sortie.deployments do %>
                  <tr>
                    <td>
                      {deployment.company_unit.custom_name || deployment.company_unit.master_unit.name}
                    </td>
                    <td>
                      <span class={damage_badge_class(deployment.damage_status)}>
                        {format_damage_status(deployment.damage_status)}
                        <%= if deployment.was_salvaged do %>
                          (Salvaged)
                        <% end %>
                      </span>
                    </td>
                    <td>
                      <span class={casualty_badge_class(deployment.pilot_casualty)}>
                        {format_casualty_status(deployment.pilot_casualty)}
                      </span>
                    </td>
                    <td class="text-right font-mono">
                      {deployment.repair_cost_sp || 0} SP
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <!-- Warchest Update -->
      <%= unless @is_completed do %>
        <div class="card bg-base-300 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title">Warchest Update</h2>
            <div class="space-y-2 text-lg">
              <div class="flex justify-between">
                <span>Current Warchest:</span>
                <span class="font-mono">{@campaign.warchest_balance || 0} SP</span>
              </div>
              <div class="flex justify-between">
                <span>Net Earnings:</span>
                <span class={[
                  "font-mono",
                  if((@sortie.net_earnings || 0) >= 0, do: "text-success", else: "text-error")
                ]}>
                  {if (@sortie.net_earnings || 0) >= 0, do: "+", else: ""}{@sortie.net_earnings || 0} SP
                </span>
              </div>
              <div class="divider my-1"></div>
              <div class="flex justify-between font-bold text-xl">
                <span>New Warchest Total:</span>
                <span class="font-mono text-primary">
                  {(@campaign.warchest_balance || 0) + (@sortie.net_earnings || 0)} SP
                </span>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <!-- Navigation -->
      <div class="flex justify-between">
        <%= if @is_completed do %>
          <.link
            navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}"}
            class="btn btn-primary"
          >
            ← Back to Campaign
          </.link>
        <% else %>
          <.link
            navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/pilots"}
            class="btn btn-ghost"
          >
            ← Back
          </.link>
          <button type="button" class="btn btn-success btn-lg" phx-click="complete_sortie">
            Complete Sortie
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_modifier(modifier) do
    percentage = round((modifier - 1.0) * 100)

    cond do
      percentage > 0 -> "+#{percentage}%"
      percentage < 0 -> "#{percentage}%"
      true -> "0%"
    end
  end

  defp damage_badge_class(status) do
    case status do
      "operational" -> "badge badge-success"
      "armor_damaged" -> "badge badge-warning"
      "structure_damaged" -> "badge badge-warning"
      "crippled" -> "badge badge-error"
      "destroyed" -> "badge badge-error"
      _ -> "badge"
    end
  end

  defp casualty_badge_class(status) do
    case status do
      "none" -> "badge badge-success"
      "wounded" -> "badge badge-warning"
      "killed" -> "badge badge-error"
      _ -> "badge"
    end
  end

  defp format_damage_status(status) do
    case status do
      "operational" -> "Operational"
      "armor_damaged" -> "Armor Damaged"
      "structure_damaged" -> "Structure Damaged"
      "crippled" -> "Crippled"
      "destroyed" -> "Destroyed"
      _ -> String.capitalize(status || "unknown")
    end
  end

  defp format_casualty_status(status) do
    case status do
      "none" -> "Unharmed"
      "wounded" -> "Wounded"
      "killed" -> "Killed"
      _ -> String.capitalize(status || "unknown")
    end
  end
end
