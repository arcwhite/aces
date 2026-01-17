defmodule AcesWeb.SortieLive.Complete.Pilots do
  @moduledoc """
  Step 4 of sortie completion wizard: Distribute SP to pilots.
  """
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
  alias Aces.Companies.{Authorization, Pilots}
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

  defp validate_sortie_status(sortie, requested_step) do
    Helpers.validate_step_access(sortie, requested_step)
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

    # First pass: calculate "desired" SP for each pilot (before pool constraint)
    desired_earnings =
      Enum.map(all_pilots, fn pilot ->
        cond do
          # Killed pilots earn nothing
          MapSet.member?(killed_pilot_ids, pilot.id) ->
            {pilot.id, %{desired_sp: 0, status: :killed, participated: true}}

          # Deceased pilots don't earn
          pilot.status == "deceased" ->
            {pilot.id, %{desired_sp: 0, status: :deceased, participated: false}}

          # Participating pilots want full share
          MapSet.member?(participating_pilot_ids, pilot.id) ->
            {pilot.id, %{desired_sp: max_sp_per_pilot, status: :active, participated: true}}

          # Non-participating pilots want half share
          true ->
            {pilot.id, %{desired_sp: div(max_sp_per_pilot, 2), status: :active, participated: false}}
        end
      end)

    # Calculate total desired SP
    total_desired = Enum.reduce(desired_earnings, 0, fn {_id, data}, acc -> acc + data.desired_sp end)

    # Determine if we need to scale down (can't give out more than net_earnings)
    # If net_earnings <= 0, nobody gets anything
    scale_factor =
      cond do
        net_earnings <= 0 -> 0.0
        total_desired <= net_earnings -> 1.0
        total_desired > 0 -> net_earnings / total_desired
        true -> 0.0
      end

    # Second pass: apply scale factor to get actual SP
    Enum.map(desired_earnings, fn {pilot_id, data} ->
      actual_sp =
        if data.desired_sp > 0 do
          # Scale down and floor to integer
          floor(data.desired_sp * scale_factor)
        else
          0
        end

      {pilot_id, %{sp: actual_sp, status: data.status, participated: data.participated}}
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

    # Only process if MVP actually changed
    if old_mvp_id != new_mvp_id do
      # First, reverse any SP allocations that were made in spend_sp step
      # This resets pilots to their baseline state before the allocations
      reverse_pilot_allocations(sortie.pilot_allocations, socket.assigns.all_pilots)

      # Remove MVP bonus from old MVP (if there was one)
      if old_mvp_id do
        old_mvp = Enum.find(socket.assigns.all_pilots, &(&1.id == old_mvp_id))
        if old_mvp do
          old_mvp
          |> Ecto.Changeset.change(%{
            sp_earned: max((old_mvp.sp_earned || 0) - 20, 0),
            sp_available: max((old_mvp.sp_available || 0) - 20, 0),
            mvp_awards: max((old_mvp.mvp_awards || 0) - 1, 0)
          })
          |> Aces.Repo.update()
        end
      end

      # Add MVP bonus to new MVP (if there is one)
      if new_mvp_id do
        new_mvp = Enum.find(socket.assigns.all_pilots, &(&1.id == new_mvp_id))
        if new_mvp do
          new_mvp
          |> Ecto.Changeset.change(%{
            sp_earned: (new_mvp.sp_earned || 0) + 20,
            sp_available: (new_mvp.sp_available || 0) + 20,
            mvp_awards: (new_mvp.mvp_awards || 0) + 1
          })
          |> Aces.Repo.update()
        end
      end

      # Update sortie with new MVP and clear pilot_allocations
      sortie
      |> Ecto.Changeset.change(%{
        mvp_pilot_id: new_mvp_id,
        pilot_allocations: %{},
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

  defp reverse_pilot_allocations(nil, _pilots), do: :ok
  defp reverse_pilot_allocations(allocations, pilots) when allocations == %{}, do: :ok
  defp reverse_pilot_allocations(allocations, pilots) do
    # For each pilot with saved allocations, reset their stats to baseline
    # and restore their sp_available
    Enum.each(allocations, fn {pilot_id_str, saved} ->
      pilot_id = String.to_integer(pilot_id_str)
      pilot = Enum.find(pilots, &(&1.id == pilot_id))

      if pilot do
        # Get the baseline values (what they had before this sortie's allocations)
        baseline_skill = saved["baseline_skill"] || 0
        baseline_tokens = saved["baseline_tokens"] || 0
        baseline_abilities = saved["baseline_abilities"] || 0
        baseline_edge_abilities = saved["baseline_edge_abilities"] || []
        sp_to_spend = saved["sp_to_spend"] || 0

        # Reset pilot to baseline and restore sp_available
        pilot
        |> Ecto.Changeset.change(%{
          sp_allocated_to_skill: baseline_skill,
          sp_allocated_to_edge_tokens: baseline_tokens,
          sp_allocated_to_edge_abilities: baseline_abilities,
          edge_abilities: baseline_edge_abilities,
          skill_level: Aces.Companies.Pilot.calculate_skill_from_sp(baseline_skill),
          edge_tokens: Aces.Companies.Pilot.calculate_edge_tokens_from_sp(baseline_tokens),
          sp_available: sp_to_spend
        })
        |> Aces.Repo.update()
      end
    end)
  end

  defp distribute_sp_to_pilots(socket, sortie, mvp_id, pilot_earnings) do
    # Calculate total pilot SP cost (sum of all SP awarded to pilots)
    # NOTE: MVP bonus is NOT included - it's "free" and doesn't come from sortie earnings
    total_pilot_sp_cost =
      Enum.reduce(socket.assigns.all_pilots, 0, fn pilot, acc ->
        earnings = Map.get(pilot_earnings, pilot.id)
        if earnings && earnings.sp > 0 do
          acc + earnings.sp
        else
          acc
        end
      end)

    # Recalculate expenses and net earnings including pilot SP cost
    # total_expenses already includes repair + rearming + casualty from costs step
    new_total_expenses = (sortie.total_expenses || 0) + total_pilot_sp_cost
    new_net_earnings = (sortie.total_income || 0) - new_total_expenses

    # Update sortie with MVP and pilot SP cost
    {:ok, _} =
      sortie
      |> Ecto.Changeset.change(%{
        mvp_pilot_id: mvp_id,
        pilot_sp_cost: total_pilot_sp_cost,
        total_expenses: new_total_expenses,
        net_earnings: new_net_earnings,
        finalization_step: "spend_sp"
      })
      |> Aces.Repo.update()

    # Update each pilot's SP
    Enum.each(socket.assigns.all_pilots, fn pilot ->
      earnings = Map.get(pilot_earnings, pilot.id)

      # Calculate base SP from earnings
      base_sp = if earnings && earnings.sp > 0, do: earnings.sp, else: 0

      # MVP bonus is given regardless of earnings (as long as pilot is eligible)
      # MVP must have participated and not be killed/deceased
      is_mvp = pilot.id == mvp_id
      mvp_bonus = if is_mvp && earnings && earnings.participated && earnings.status == :active, do: 20, else: 0

      total_sp = base_sp + mvp_bonus

      # Only update if there's something to give (SP or MVP bonus) or if they participated
      if total_sp > 0 || (earnings && earnings.participated) do
        new_sp_earned = (pilot.sp_earned || 0) + total_sp
        new_sp_available = (pilot.sp_available || 0) + total_sp
        new_sorties = (pilot.sorties_participated || 0) + if(earnings && earnings.participated, do: 1, else: 0)
        new_mvp_awards = (pilot.mvp_awards || 0) + if(is_mvp && mvp_bonus > 0, do: 1, else: 0)

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
