defmodule AcesWeb.SortieLive.Complete.Pilots do
  @moduledoc """
  Step 4 of sortie completion wizard: Distribute SP to pilots.
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

    with :ok <- authorize_access(user, company),
         :ok <- validate_sortie_belongs_to_campaign(sortie, campaign, company),
         :ok <- validate_sortie_status(sortie, "pilots") do
      # Get all pilots in the company
      all_pilots = Companies.list_pilots(company)

      # Get pilot IDs who participated in this sortie
      participating_pilot_ids =
        sortie.deployments
        |> Enum.filter(& &1.pilot_id)
        |> Enum.map(& &1.pilot_id)
        |> MapSet.new()

      # Calculate pilot earnings
      pilot_earnings = calculate_pilot_earnings(sortie, all_pilots, participating_pilot_ids)

      {:ok,
       socket
       |> assign(:company, company)
       |> assign(:campaign, campaign)
       |> assign(:sortie, sortie)
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

  defp validate_sortie_status(sortie, expected_step) do
    cond do
      sortie.status != "finalizing" ->
        {:error, "Sortie must be in finalizing state",
         ~p"/companies/#{sortie.campaign.company_id}/campaigns/#{sortie.campaign_id}/sorties/#{sortie.id}"}

      sortie.finalization_step != expected_step ->
        {:error, "Please complete the previous step first",
         ~p"/companies/#{sortie.campaign.company_id}/campaigns/#{sortie.campaign_id}/sorties/#{sortie.id}/complete/#{sortie.finalization_step}"}

      true ->
        :ok
    end
  end

  defp calculate_pilot_earnings(sortie, all_pilots, participating_pilot_ids) do
    net_earnings = sortie.net_earnings || 0
    max_sp_per_pilot = sortie.sp_per_participating_pilot || 0

    # Find killed pilots (they earn nothing)
    killed_pilot_ids =
      sortie.deployments
      |> Enum.filter(&(&1.pilot_casualty == "killed" && &1.pilot_id))
      |> Enum.map(& &1.pilot_id)
      |> MapSet.new()

    # Calculate earnings for each pilot
    Enum.map(all_pilots, fn pilot ->
      cond do
        # Killed pilots earn nothing
        MapSet.member?(killed_pilot_ids, pilot.id) ->
          {pilot.id, %{sp: 0, status: :killed, participated: true}}

        # Deceased pilots don't earn
        pilot.status == "deceased" ->
          {pilot.id, %{sp: 0, status: :deceased, participated: false}}

        # Participating pilots get full share (up to max)
        MapSet.member?(participating_pilot_ids, pilot.id) ->
          sp = if net_earnings > 0, do: min(max_sp_per_pilot, net_earnings), else: 0
          {pilot.id, %{sp: sp, status: :active, participated: true}}

        # Non-participating pilots get half share
        true ->
          sp = if net_earnings > 0, do: min(div(max_sp_per_pilot, 2), net_earnings), else: 0
          {pilot.id, %{sp: sp, status: :active, participated: false}}
      end
    end)
    |> Map.new()
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

    # Update sortie with MVP
    {:ok, _} =
      sortie
      |> Ecto.Changeset.change(%{
        mvp_pilot_id: mvp_id,
        finalization_step: "summary"
      })
      |> Aces.Repo.update()

    # Update each pilot's SP
    Enum.each(socket.assigns.all_pilots, fn pilot ->
      earnings = Map.get(pilot_earnings, pilot.id)

      if earnings && earnings.sp > 0 do
        # Add MVP bonus if this is the MVP
        bonus = if pilot.id == mvp_id, do: 20, else: 0
        total_sp = earnings.sp + bonus

        # Update pilot's sp_earned and sp_available
        new_sp_earned = (pilot.sp_earned || 0) + total_sp
        new_sp_available = (pilot.sp_available || 0) + total_sp
        new_sorties = (pilot.sorties_participated || 0) + if(earnings.participated, do: 1, else: 0)
        new_mvp_awards = (pilot.mvp_awards || 0) + if(pilot.id == mvp_id, do: 1, else: 0)

        pilot
        |> Ecto.Changeset.change(%{
          sp_earned: new_sp_earned,
          sp_available: new_sp_available,
          sorties_participated: new_sorties,
          mvp_awards: new_mvp_awards
        })
        |> Aces.Repo.update()
      end
    end)

    # Mark wounded/killed pilots
    Enum.each(sortie.deployments, fn deployment ->
      if deployment.pilot_id do
        case deployment.pilot_casualty do
          "wounded" ->
            deployment.pilot
            |> Ecto.Changeset.change(%{status: "wounded"})
            |> Aces.Repo.update()

          "killed" ->
            deployment.pilot
            |> Ecto.Changeset.change(%{status: "deceased"})
            |> Aces.Repo.update()

          _ ->
            :ok
        end
      end
    end)

    {:noreply,
     push_navigate(socket,
       to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{socket.assigns.campaign.id}/sorties/#{sortie.id}/complete/summary"
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
        <div class="mt-6">
          <ul class="steps steps-horizontal w-full">
            <li class="step step-primary">Victory Details</li>
            <li class="step step-primary">Unit Status</li>
            <li class="step step-primary">Costs</li>
            <li class="step step-primary">Pilot SP</li>
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
                if(@sortie.net_earnings >= 0, do: "text-success", else: "text-error")
              ]}>
                {@sortie.net_earnings} SP
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

          <select
            class="select select-bordered w-full max-w-md"
            phx-change="select_mvp"
            name="pilot_id"
          >
            <option value="">Select MVP...</option>
            <%= for pilot <- @all_pilots do %>
              <% earnings = Map.get(@pilot_earnings, pilot.id) %>
              <%= if earnings.participated and earnings.status not in [:killed, :deceased] do %>
                <option value={pilot.id} selected={pilot.id == @selected_mvp_id}>
                  {pilot.name} {if pilot.callsign, do: "(#{pilot.callsign})", else: ""}
                </option>
              <% end %>
            <% end %>
          </select>
        </div>
      </div>

      <!-- Note about SP allocation -->
      <div class="alert alert-info mb-6">
        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
        </svg>
        <span>
          SP will be added to each pilot's available pool. Pilots can allocate their SP to skills, edge tokens, and edge abilities from the company roster screen.
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
          Continue to Summary →
        </button>
      </div>
    </div>
    """
  end
end
