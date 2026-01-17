defmodule AcesWeb.SortieLive.Complete.Costs do
  @moduledoc """
  Step 3 of sortie completion wizard: Review costs and expenses.
  """
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
  alias Aces.Companies.Authorization
  alias Aces.Campaigns.Deployment
  alias AcesWeb.SortieLive.Complete.Helpers

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(%{"company_id" => company_id, "campaign_id" => campaign_id, "id" => sortie_id}, _session, socket) do
    company = Companies.get_company!(company_id)
    campaign = Campaigns.get_campaign!(campaign_id)
    sortie = Campaigns.get_sortie!(sortie_id)
    user = socket.assigns.current_scope.user

    with :ok <- authorize_access(user, company),
         :ok <- validate_sortie_belongs_to_campaign(sortie, campaign, company),
         :ok <- validate_sortie_status(sortie, "costs") do
      # Calculate all costs
      costs = calculate_all_costs(sortie)

      {:ok,
       socket
       |> assign(:company, company)
       |> assign(:campaign, campaign)
       |> assign(:sortie, sortie)
       |> assign(:page_title, "Complete Sortie: Costs & Expenses")
       |> assign(:costs, costs)}
    else
      {:error, message, redirect_path} ->
        {:ok,
         socket
         |> put_flash(:error, message)
         |> push_navigate(to: redirect_path)}
    end
  end

  defp authorize_access(user, company) do
    if Authorization.can?(:edit_company, user, company) do
      :ok
    else
      {:error, "You don't have permission to complete this sortie",
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

  defp validate_sortie_status(sortie, requested_step) do
    Helpers.validate_step_access(sortie, requested_step)
  end

  defp calculate_all_costs(sortie) do
    deployments = sortie.deployments

    # Calculate repair costs per deployment
    # If a destroyed unit was salvaged, treat it as "salvageable" for cost purposes
    repair_costs =
      Enum.map(deployments, fn d ->
        effective_status =
          if d.damage_status == "destroyed" and d.was_salvaged do
            "salvageable"
          else
            d.damage_status
          end

        repair_cost = Deployment.calculate_unit_repair_cost(d.company_unit.master_unit, effective_status)
        {d.id, repair_cost}
      end)
      |> Map.new()

    # Calculate rearming costs (20 SP per unit, unless ENE)
    rearming_costs =
      Enum.map(deployments, fn d ->
        cost = Deployment.get_rearming_cost(d)
        {d.id, cost}
      end)
      |> Map.new()

    # Calculate casualty costs
    casualty_costs =
      Enum.map(deployments, fn d ->
        cost = if d.pilot_casualty in ["wounded", "killed"], do: 100, else: 0
        {d.id, cost}
      end)
      |> Map.new()

    total_repair = Enum.sum(Map.values(repair_costs))
    total_rearming = Enum.sum(Map.values(rearming_costs))
    total_casualty = Enum.sum(Map.values(casualty_costs))
    total_expenses = total_repair + total_rearming + total_casualty

    # Calculate adjusted income
    base_income =
      (sortie.primary_objective_income || 0) +
        (sortie.secondary_objectives_income || 0) +
        (sortie.waypoints_income || 0) -
        (sortie.recon_total_cost || 0)

    adjusted_income = round(base_income * sortie.campaign.reward_modifier)
    net_earnings = adjusted_income - total_expenses

    %{
      repair_costs: repair_costs,
      rearming_costs: rearming_costs,
      casualty_costs: casualty_costs,
      total_repair: total_repair,
      total_rearming: total_rearming,
      total_casualty: total_casualty,
      total_expenses: total_expenses,
      base_income: base_income,
      adjusted_income: adjusted_income,
      net_earnings: net_earnings
    }
  end

  @impl true
  def handle_event("save", _params, socket) do
    sortie = socket.assigns.sortie
    costs = socket.assigns.costs

    # Update sortie with calculated costs
    {:ok, _} =
      sortie
      |> Ecto.Changeset.change(%{
        rearming_cost: costs.total_rearming,
        total_income: costs.adjusted_income,
        total_expenses: costs.total_expenses,
        net_earnings: costs.net_earnings,
        finalization_step: "pilots"
      })
      |> Aces.Repo.update()

    # Update each deployment with calculated costs
    Enum.each(sortie.deployments, fn d ->
      d
      |> Ecto.Changeset.change(%{
        repair_cost_sp: Map.get(costs.repair_costs, d.id, 0),
        casualty_cost_sp: Map.get(costs.casualty_costs, d.id, 0)
      })
      |> Aces.Repo.update()
    end)

    {:noreply,
     push_navigate(socket,
       to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{socket.assigns.campaign.id}/sorties/#{sortie.id}/complete/pilots"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-4xl">
      <!-- Header -->
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <.link
            navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/damage"}
            class="btn btn-ghost btn-sm"
          >
            ← Back to Unit Status
          </.link>
        </div>

        <h1 class="text-3xl font-bold mb-2">Complete Sortie: Costs & Expenses</h1>
        <p class="text-lg opacity-70">
          Sortie #{@sortie.mission_number}: {@sortie.name}
        </p>

        <!-- Progress Steps -->
        <div class="mt-6">
          <ul class="steps steps-horizontal w-full">
            <li class="step step-primary">Victory Details</li>
            <li class="step step-primary">Unit Status</li>
            <li class="step step-primary">Costs</li>
            <li class="step">Pilot SP</li>
            <li class="step">Spend SP</li>
            <li class="step">Summary</li>
          </ul>
        </div>
      </div>

      <!-- Repair Costs -->
      <div class="card bg-base-200 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title">Repair Costs</h2>
          <div class="overflow-x-auto">
            <table class="table w-full">
              <thead>
                <tr>
                  <th>Unit</th>
                  <th>Damage Status</th>
                  <th class="text-right">Repair Cost</th>
                </tr>
              </thead>
              <tbody>
                <%= for deployment <- @sortie.deployments do %>
                  <% effective_status = effective_damage_status(deployment) %>
                  <tr>
                    <td>
                      {deployment.company_unit.custom_name || deployment.company_unit.master_unit.name}
                    </td>
                    <td>
                      <span class={damage_badge_class(effective_status)}>
                        {format_damage_status(effective_status)}
                      </span>
                    </td>
                    <td class="text-right font-mono">
                      {Map.get(@costs.repair_costs, deployment.id, 0)} SP
                    </td>
                  </tr>
                <% end %>
              </tbody>
              <tfoot>
                <tr class="font-bold">
                  <td colspan="2">Total Repair Costs</td>
                  <td class="text-right font-mono">{@costs.total_repair} SP</td>
                </tr>
              </tfoot>
            </table>
          </div>
        </div>
      </div>

      <!-- Rearming Costs -->
      <div class="card bg-base-200 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title">Re-arming Costs</h2>
          <p class="text-sm opacity-70 mb-4">20 SP per unit (units with ENE are exempt)</p>
          <div class="overflow-x-auto">
            <table class="table w-full">
              <thead>
                <tr>
                  <th>Unit</th>
                  <th>ENE Exempt?</th>
                  <th class="text-right">Re-arm Cost</th>
                </tr>
              </thead>
              <tbody>
                <%= for deployment <- @sortie.deployments do %>
                  <% is_exempt = !Aces.Campaigns.Deployment.needs_rearming?(deployment) %>
                  <tr>
                    <td>
                      {deployment.company_unit.custom_name || deployment.company_unit.master_unit.name}
                    </td>
                    <td>
                      <%= if is_exempt do %>
                        <span class="badge badge-success">ENE</span>
                      <% else %>
                        <span class="opacity-50">—</span>
                      <% end %>
                    </td>
                    <td class="text-right font-mono">
                      {Map.get(@costs.rearming_costs, deployment.id, 0)} SP
                    </td>
                  </tr>
                <% end %>
              </tbody>
              <tfoot>
                <tr class="font-bold">
                  <td colspan="2">Total Re-arming Costs</td>
                  <td class="text-right font-mono">{@costs.total_rearming} SP</td>
                </tr>
              </tfoot>
            </table>
          </div>
        </div>
      </div>

      <!-- Casualty Costs -->
      <div class="card bg-base-200 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title">Casualty Costs</h2>
          <p class="text-sm opacity-70 mb-4">100 SP to heal/replace wounded or killed crew</p>
          <div class="overflow-x-auto">
            <table class="table w-full">
              <thead>
                <tr>
                  <th>Unit</th>
                  <th>Pilot/Crew</th>
                  <th>Status</th>
                  <th class="text-right">Cost</th>
                </tr>
              </thead>
              <tbody>
                <%= for deployment <- @sortie.deployments do %>
                  <tr>
                    <td>
                      {deployment.company_unit.custom_name || deployment.company_unit.master_unit.name}
                    </td>
                    <td>
                      <%= if deployment.pilot do %>
                        {deployment.pilot.name}
                      <% else %>
                        <span class="opacity-50">Unnamed crew</span>
                      <% end %>
                    </td>
                    <td>
                      <span class={casualty_badge_class(deployment.pilot_casualty)}>
                        {format_casualty_status(deployment.pilot_casualty)}
                      </span>
                    </td>
                    <td class="text-right font-mono">
                      {Map.get(@costs.casualty_costs, deployment.id, 0)} SP
                    </td>
                  </tr>
                <% end %>
              </tbody>
              <tfoot>
                <tr class="font-bold">
                  <td colspan="3">Total Casualty Costs</td>
                  <td class="text-right font-mono">{@costs.total_casualty} SP</td>
                </tr>
              </tfoot>
            </table>
          </div>
        </div>
      </div>

      <!-- Summary -->
      <div class="card bg-base-300 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title">Financial Summary</h2>
          <div class="space-y-2">
            <div class="flex justify-between">
              <span>Adjusted Income:</span>
              <span class="font-mono font-bold text-success">{@costs.adjusted_income} SP</span>
            </div>
            <div class="flex justify-between">
              <span>Total Repair Costs:</span>
              <span class="font-mono text-error">-{@costs.total_repair} SP</span>
            </div>
            <div class="flex justify-between">
              <span>Total Re-arming Costs:</span>
              <span class="font-mono text-error">-{@costs.total_rearming} SP</span>
            </div>
            <div class="flex justify-between">
              <span>Total Casualty Costs:</span>
              <span class="font-mono text-error">-{@costs.total_casualty} SP</span>
            </div>
            <div class="divider my-1"></div>
            <div class="flex justify-between text-lg font-bold">
              <span>Net Earnings:</span>
              <span class={[
                "font-mono",
                if(@costs.net_earnings >= 0, do: "text-success", else: "text-error")
              ]}>
                {@costs.net_earnings} SP
              </span>
            </div>
          </div>

          <%= if @costs.net_earnings < 0 do %>
            <div class="alert alert-warning mt-4">
              <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
              </svg>
              <span>Negative earnings will be deducted from your company warchest.</span>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Navigation -->
      <div class="flex justify-between">
        <.link
          navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/damage"}
          class="btn btn-ghost"
        >
          ← Back
        </.link>
        <button type="button" class="btn btn-primary" phx-click="save">
          Continue to Pilot SP →
        </button>
      </div>
    </div>
    """
  end

  defp effective_damage_status(deployment) do
    if deployment.damage_status == "destroyed" and deployment.was_salvaged do
      "salvageable"
    else
      deployment.damage_status
    end
  end

  defp damage_badge_class(status) do
    case status do
      "operational" -> "badge badge-success"
      "armor_damaged" -> "badge badge-warning"
      "structure_damaged" -> "badge badge-warning"
      "crippled" -> "badge badge-error"
      "salvageable" -> "badge badge-warning"
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
      "salvageable" -> "Salvageable"
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
