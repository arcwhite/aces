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
    all_pilots = socket.assigns.all_pilots
    already_distributed = (sortie.pilot_sp_cost || 0) > 0

    result =
      if already_distributed do
        # SP was already distributed - only handle MVP changes
        Campaigns.handle_mvp_change(sortie, sortie.mvp_pilot_id, mvp_id, all_pilots)
      else
        # First time through - distribute SP to pilots
        Campaigns.distribute_pilot_sp(sortie, all_pilots, pilot_earnings, mvp_id)
      end

    socket =
      case result do
        {:ok, _updated_sortie} ->
          socket

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
          error_message = "Failed to save: #{inspect(errors)}"
          put_flash(socket, :error, error_message)

        {:error, message} when is_binary(message) ->
          put_flash(socket, :error, "Failed to save: #{message}")

        {:error, error} ->
          put_flash(socket, :error, "Failed to save: #{inspect(error)}")
      end

    {:noreply,
     push_navigate(socket,
       to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{socket.assigns.campaign.id}/sorties/#{sortie.id}/complete/spend_sp"
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
        <div class="mt-6 overflow-x-auto">
          <ul class="steps steps-horizontal w-full min-w-[500px]">
            <li class="step step-primary text-xs md:text-sm">Victory</li>
            <li class="step step-primary text-xs md:text-sm">Damage</li>
            <li class="step step-primary text-xs md:text-sm">Costs</li>
            <li class="step step-primary text-xs md:text-sm">Pilot SP</li>
            <li class="step text-xs md:text-sm">Spend SP</li>
            <li class="step text-xs md:text-sm">Summary</li>
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
                  <th class="hidden sm:table-cell">Joined</th>
                  <th>Status</th>
                  <th class="text-right">SP</th>
                </tr>
              </thead>
              <tbody>
                <%= for pilot <- @all_pilots do %>
                  <% earnings = Map.get(@pilot_earnings, pilot.id) %>
                  <tr class={if(earnings.status == :killed or earnings.status == :deceased, do: "opacity-50", else: "")}>
                    <td>
                      <div class="font-semibold text-sm">{pilot.name}</div>
                      <%= if pilot.callsign do %>
                        <div class="text-xs opacity-70 hidden sm:block">"{pilot.callsign}"</div>
                      <% end %>
                    </td>
                    <td class="hidden sm:table-cell">
                      <%= if earnings.participated do %>
                        <span class="badge badge-primary badge-sm">Yes</span>
                      <% else %>
                        <span class="badge badge-ghost badge-sm">No</span>
                      <% end %>
                    </td>
                    <td>
                      <%= case earnings.status do %>
                        <% :killed -> %>
                          <span class="badge badge-error badge-xs sm:badge-md whitespace-nowrap">KIA</span>
                        <% :deceased -> %>
                          <span class="badge badge-error badge-xs sm:badge-md whitespace-nowrap">Deceased</span>
                        <% :wounded -> %>
                          <span class="badge badge-warning badge-xs sm:badge-md whitespace-nowrap">Wounded</span>
                        <% _ -> %>
                          <span class="badge badge-success badge-xs sm:badge-md whitespace-nowrap">Active</span>
                      <% end %>
                    </td>
                    <td class="text-right font-mono whitespace-nowrap">
                      <%= if earnings.status == :killed do %>
                        <span class="opacity-50">—</span>
                      <% else %>
                        {earnings.sp}
                        <%= if pilot.id == @selected_mvp_id do %>
                          <span class="text-warning text-xs ml-1">+20</span>
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
