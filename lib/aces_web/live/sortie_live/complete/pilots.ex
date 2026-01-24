defmodule AcesWeb.SortieLive.Complete.Pilots do
  @moduledoc """
  Step 4 of sortie completion wizard: Distribute SP to pilots.
  """
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
  alias Aces.Companies.{Authorization, Pilots}
  alias Aces.Campaigns.SortieCompletion
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
         :ok <- validate_sortie_status(sortie, "pilots") do
      # Get all pilots in the company
      all_pilots = Pilots.list_company_pilots(company)

      # Get pilot IDs who participated in this sortie
      participating_pilot_ids =
        sortie.deployments
        |> Enum.filter(& &1.pilot_id)
        |> Enum.map(& &1.pilot_id)
        |> MapSet.new()

      # Calculate operational costs (same as Costs screen) to get the correct net earnings
      # before pilot SP distribution
      costs = SortieCompletion.calculate_all_costs(sortie)

      # Calculate pilot earnings using business logic module, passing the correct net earnings
      pilot_earnings = SortieCompletion.calculate_pilot_earnings(
        sortie,
        all_pilots,
        participating_pilot_ids,
        net_earnings: costs.net_earnings
      )

      {:ok,
       socket
       |> assign(:company, company)
       |> assign(:campaign, campaign)
       |> assign(:sortie, sortie)
       |> assign(:costs, costs)
       |> assign(:all_pilots, all_pilots)
       |> assign(:participating_pilot_ids, participating_pilot_ids)
       |> assign(:pilot_earnings, pilot_earnings)
       |> assign(:selected_mvp_id, sortie.mvp_pilot_id)
       |> assign(:page_title, "Complete Sortie: Pilot SP")}
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

  @impl true
  def handle_event("select_mvp", %{"pilot_id" => pilot_id}, socket) do
    mvp_id = if pilot_id == "", do: nil, else: String.to_integer(pilot_id)
    {:noreply, assign(socket, :selected_mvp_id, mvp_id)}
  end

  @impl true
  def handle_event("save", _params, socket) do
    sortie = socket.assigns.sortie
    mvp_id = socket.assigns.selected_mvp_id
    pilot_earnings = socket.assigns.pilot_earnings
    already_distributed = (sortie.pilot_sp_cost || 0) > 0

    if already_distributed do
      # SP was already distributed - only handle MVP changes
      handle_mvp_change_only(socket, sortie, mvp_id)
    else
      # First time through - distribute SP to pilots
      distribute_sp_to_pilots(socket, sortie, mvp_id, pilot_earnings)
    end

    {:noreply,
     push_navigate(socket,
       to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{socket.assigns.campaign.id}/sorties/#{sortie.id}/complete/spend_sp"
     )}
  end

  defp handle_mvp_change_only(socket, sortie, new_mvp_id) do
    old_mvp_id = sortie.mvp_pilot_id
    all_pilots = socket.assigns.all_pilots

    # Only process if MVP actually changed
    if old_mvp_id != new_mvp_id do
      # First, reverse any SP allocations that were made in spend_sp step
      apply_pilot_reversals(sortie.id, all_pilots)

      # Delete pilot allocations from database
      Campaigns.delete_sortie_pilot_allocations(sortie.id)

      # Apply MVP changes using business logic module
      mvp_changes = SortieCompletion.calculate_mvp_change(old_mvp_id, new_mvp_id, all_pilots)

      if mvp_changes.old_mvp_changes do
        old_mvp = Enum.find(all_pilots, &(&1.id == old_mvp_id))
        if old_mvp do
          old_mvp
          |> Ecto.Changeset.change(mvp_changes.old_mvp_changes)
          |> Aces.Repo.update()
        end
      end

      if mvp_changes.new_mvp_changes do
        new_mvp = Enum.find(all_pilots, &(&1.id == new_mvp_id))
        if new_mvp do
          new_mvp
          |> Ecto.Changeset.change(mvp_changes.new_mvp_changes)
          |> Aces.Repo.update()
        end
      end

      # Update sortie with new MVP
      sortie
      |> Ecto.Changeset.change(%{
        mvp_pilot_id: new_mvp_id,
        finalization_step: "spend_sp"
      })
      |> Aces.Repo.update()
    else
      # Just update finalization step
      sortie
      |> Ecto.Changeset.change(%{finalization_step: "spend_sp"})
      |> Aces.Repo.update()
    end
  end

  defp apply_pilot_reversals(sortie_id, all_pilots) do
    reversals = SortieCompletion.reverse_pilot_allocations(sortie_id, all_pilots)

    Enum.each(reversals, fn {pilot_id, changes} ->
      pilot = Enum.find(all_pilots, &(&1.id == pilot_id))
      if pilot do
        pilot
        |> Ecto.Changeset.change(changes)
        |> Aces.Repo.update()
      end
    end)
  end

  defp distribute_sp_to_pilots(socket, sortie, mvp_id, pilot_earnings) do
    all_pilots = socket.assigns.all_pilots

    # Use business logic module to calculate distribution
    distribution = SortieCompletion.distribute_sp_to_pilots(all_pilots, pilot_earnings, mvp_id)

    # Recalculate expenses and net earnings including pilot SP cost
    new_total_expenses = (sortie.total_expenses || 0) + distribution.total_pilot_sp_cost
    new_net_earnings = (sortie.total_income || 0) - new_total_expenses

    # Update sortie with MVP and pilot SP cost
    {:ok, _} =
      sortie
      |> Ecto.Changeset.change(%{
        mvp_pilot_id: mvp_id,
        pilot_sp_cost: distribution.total_pilot_sp_cost,
        total_expenses: new_total_expenses,
        net_earnings: new_net_earnings,
        finalization_step: "spend_sp"
      })
      |> Aces.Repo.update()

    # Apply pilot changes
    Enum.each(distribution.pilot_changes, fn {pilot_id, changes} ->
      pilot = Enum.find(all_pilots, &(&1.id == pilot_id))
      if pilot do
        pilot
        |> Ecto.Changeset.change(changes)
        |> Aces.Repo.update()
      end
    end)

    # Apply casualty updates using business logic module
    casualty_updates = SortieCompletion.build_casualty_updates(sortie.deployments)

    Enum.each(casualty_updates, fn {pilot_id, changes} ->
      deployment = Enum.find(sortie.deployments, &(&1.pilot_id == pilot_id))
      if deployment && deployment.pilot do
        deployment.pilot
        |> Ecto.Changeset.change(changes)
        |> Aces.Repo.update()
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-4xl">
      <!-- Header -->
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <.link
            navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/costs"}
            class="btn btn-ghost btn-sm"
          >
            ← Back to Costs
          </.link>
        </div>

        <h1 class="text-3xl font-bold mb-2">Complete Sortie: Pilot SP Distribution</h1>
        <p class="text-lg opacity-70">
          Sortie #{@sortie.mission_number}: {@sortie.name}
        </p>

        <!-- Progress Steps -->
        <div class="mt-6">
          <ul class="steps steps-horizontal w-full">
            <li class="step step-primary">Victory Details</li>
            <li class="step step-primary">Unit Status</li>
            <li class="step step-primary">Costs</li>
            <li class="step step-primary">Pilot SP</li>
            <li class="step">Spend SP</li>
            <li class="step">Summary</li>
          </ul>
        </div>
      </div>

      <!-- Earnings Summary -->
      <div class="card bg-base-200 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title">SP Distribution</h2>
          <div class="stats shadow">
            <div class="stat">
              <div class="stat-title">Net Earnings</div>
              <div class={[
                "stat-value",
                if(@costs.net_earnings >= 0, do: "text-success", else: "text-error")
              ]}>
                {@costs.net_earnings} SP
              </div>
            </div>
            <div class="stat">
              <div class="stat-title">Max SP Per Pilot</div>
              <div class="stat-value">{@sortie.sp_per_participating_pilot}</div>
            </div>
          </div>
        </div>
      </div>

      <!-- Pilot Earnings Table -->
      <div class="card bg-base-200 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title">Pilot Earnings</h2>
          <div class="overflow-x-auto">
            <table class="table w-full">
              <thead>
                <tr>
                  <th>Pilot</th>
                  <th>Participated</th>
                  <th>Status</th>
                  <th class="text-right">SP Earned</th>
                </tr>
              </thead>
              <tbody>
                <%= for pilot <- @all_pilots do %>
                  <% earnings = Map.get(@pilot_earnings, pilot.id) %>
                  <tr class={if(earnings.status == :killed or earnings.status == :deceased, do: "opacity-50", else: "")}>
                    <td>
                      <div class="font-semibold">{pilot.name}</div>
                      <%= if pilot.callsign do %>
                        <div class="text-sm opacity-70">"{pilot.callsign}"</div>
                      <% end %>
                    </td>
                    <td>
                      <%= if earnings.participated do %>
                        <span class="badge badge-primary">Yes</span>
                      <% else %>
                        <span class="badge badge-ghost">No</span>
                      <% end %>
                    </td>
                    <td>
                      <%= case earnings.status do %>
                        <% :killed -> %>
                          <span class="badge badge-error">Killed in Action</span>
                        <% :deceased -> %>
                          <span class="badge badge-error">Deceased</span>
                        <% :wounded -> %>
                          <span class="badge badge-warning">Wounded</span>
                        <% _ -> %>
                          <span class="badge badge-success">Active</span>
                      <% end %>
                    </td>
                    <td class="text-right font-mono">
                      <%= if earnings.status == :killed do %>
                        <span class="opacity-50">—</span>
                      <% else %>
                        {earnings.sp} SP
                        <%= if pilot.id == @selected_mvp_id do %>
                          <span class="text-warning ml-1">+20 MVP</span>
                        <% end %>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <!-- MVP Selection -->
      <div class="card bg-base-200 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title">Select MVP</h2>
          <p class="text-sm opacity-70 mb-4">
            The MVP receives an additional 20 SP bonus (not deducted from earnings).
          </p>

          <form phx-change="select_mvp">
            <select
              name="pilot_id"
              class="select select-bordered w-full max-w-md"
              phx-change="select_mvp"
              id={"mvp-select-#{@selected_mvp_id || "none"}"}
            >
              <option value="" selected={is_nil(@selected_mvp_id)}>Select MVP...</option>
              <%= for pilot <- @all_pilots do %>
                <% earnings = Map.get(@pilot_earnings, pilot.id) %>
                <%= if earnings.participated and earnings.status not in [:killed, :deceased] do %>
                  <option value={pilot.id} selected={pilot.id == @selected_mvp_id}>
                    {pilot.name} {if pilot.callsign, do: "(#{pilot.callsign})", else: ""}
                  </option>
                <% end %>
              <% end %>
            </select>
          </form>
        </div>
      </div>

      <!-- Note about SP allocation -->
      <div class="alert alert-info mb-6">
        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
        </svg>
        <span>
          SP will be added to each pilot's available pool. You'll allocate SP to skills, edge tokens, and edge abilities on the next screen.
        </span>
      </div>

      <!-- Navigation -->
      <div class="flex justify-between">
        <.link
          navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/costs"}
          class="btn btn-ghost"
        >
          ← Back
        </.link>
        <button type="button" class="btn btn-primary" phx-click="save">
          Continue to Spend SP →
        </button>
      </div>
    </div>
    """
  end
end
