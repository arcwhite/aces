defmodule AcesWeb.Components.SortieSummary do
  @moduledoc """
  Reusable component for displaying sortie summary information.
  Used by both the completed sortie show view and the finalization wizard.
  """
  use Phoenix.Component

  @doc """
  Renders the complete sortie summary including mission details, financial summary,
  unit status, and pilot SP allocations.

  ## Attributes

    * `:sortie` - The sortie struct with preloaded deployments, pilots, etc.
    * `:campaign` - The campaign struct (for difficulty modifier display)
    * `:pilot_allocations` - List of PilotAllocation structs for this sortie (optional)
    * `:all_pilots` - List of all pilots in the company (optional, for displaying names)

  """
  attr :sortie, :map, required: true
  attr :campaign, :map, required: true
  attr :pilot_allocations, :list, default: []
  attr :all_pilots, :list, default: []

  def sortie_summary(assigns) do
    # Prepare pilot allocations with pilot names for display
    assigns = assign(assigns, :enriched_allocations, enrich_allocations(assigns))

    ~H"""
    <div class="space-y-6">
      <!-- Mission Details -->
      <.mission_details sortie={@sortie} />

      <!-- Financial Summary -->
      <.financial_summary sortie={@sortie} campaign={@campaign} />

      <!-- Unit Status -->
      <.unit_status sortie={@sortie} />

      <!-- Pilot SP Allocations -->
      <%= if length(@enriched_allocations) > 0 do %>
        <.pilot_allocations allocations={@enriched_allocations} />
      <% end %>
    </div>
    """
  end

  defp enrich_allocations(%{pilot_allocations: allocations, all_pilots: pilots, sortie: sortie}) do
    mvp_pilot_id = sortie.mvp_pilot_id

    # Build lookup map first for O(1) lookups instead of O(n) Enum.find per allocation
    pilot_map = Map.new(pilots, &{&1.id, &1})

    allocations
    |> Enum.filter(&(&1.allocation_type == "sortie"))
    |> Enum.map(fn alloc ->
      pilot = Map.get(pilot_map, alloc.pilot_id)

      %{
        pilot_id: alloc.pilot_id,
        pilot_name: if(pilot, do: pilot.name, else: "Unknown Pilot"),
        pilot_callsign: if(pilot, do: pilot.callsign, else: nil),
        sp_to_skill: alloc.sp_to_skill || 0,
        sp_to_tokens: alloc.sp_to_tokens || 0,
        sp_to_abilities: alloc.sp_to_abilities || 0,
        total_sp: alloc.total_sp || 0,
        edge_abilities_gained: alloc.edge_abilities_gained || [],
        is_mvp: alloc.pilot_id == mvp_pilot_id
      }
    end)
    |> Enum.sort_by(& &1.pilot_name)
  end

  defp enrich_allocations(_), do: []

  @doc """
  Renders mission details section.
  """
  attr :sortie, :map, required: true

  def mission_details(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-xl">
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

        <%= if @sortie.recon_notes && String.trim(@sortie.recon_notes) != "" do %>
          <div class="mt-4">
            <div class="text-sm opacity-70 mb-2">Mission Notes</div>
            <p class="whitespace-pre-wrap text-sm bg-base-300 p-3 rounded-lg">{@sortie.recon_notes}</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders the financial summary section with income and expense breakdown.
  """
  attr :sortie, :map, required: true
  attr :campaign, :map, required: true

  def financial_summary(assigns) do
    # Calculate expense breakdown
    repair_cost =
      Enum.reduce(assigns.sortie.deployments, 0, fn d, acc ->
        acc + (d.repair_cost_sp || 0)
      end)

    rearming_cost = assigns.sortie.rearming_cost || 0
    pilot_sp_cost = assigns.sortie.pilot_sp_cost || 0
    total_expenses = assigns.sortie.total_expenses || 0
    casualty_cost = total_expenses - pilot_sp_cost - repair_cost - rearming_cost

    assigns =
      assigns
      |> assign(:repair_cost, repair_cost)
      |> assign(:rearming_cost, rearming_cost)
      |> assign(:pilot_sp_cost, pilot_sp_cost)
      |> assign(:casualty_cost, max(casualty_cost, 0))

    ~H"""
    <div class="card bg-base-200 shadow-xl">
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

          <!-- Expense Breakdown -->
          <div class="text-sm opacity-70 mt-2">Expenses:</div>
          <%= if @repair_cost > 0 do %>
            <div class="flex justify-between text-error pl-4">
              <span>Repair Costs:</span>
              <span class="font-mono">-{@repair_cost} SP</span>
            </div>
          <% end %>
          <%= if @rearming_cost > 0 do %>
            <div class="flex justify-between text-error pl-4">
              <span>Rearming Costs:</span>
              <span class="font-mono">-{@rearming_cost} SP</span>
            </div>
          <% end %>
          <%= if @casualty_cost > 0 do %>
            <div class="flex justify-between text-error pl-4">
              <span>Casualty Costs:</span>
              <span class="font-mono">-{@casualty_cost} SP</span>
            </div>
          <% end %>
          <%= if @pilot_sp_cost > 0 do %>
            <div class="flex justify-between text-error pl-4">
              <span>Pilot SP Allocation:</span>
              <span class="font-mono">-{@pilot_sp_cost} SP</span>
            </div>
          <% end %>
          <div class="flex justify-between text-error font-semibold">
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
    """
  end

  @doc """
  Renders the unit status table showing damage, crew status, and repair costs.
  """
  attr :sortie, :map, required: true

  def unit_status(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">Unit Status</h2>
        <div class="overflow-x-auto">
          <table class="table table-sm w-full">
            <thead>
              <tr>
                <th>Unit</th>
                <th>Pilot/Crew</th>
                <th>Damage</th>
                <th>Crew Status</th>
                <th class="text-right">Repair Cost</th>
              </tr>
            </thead>
            <tbody>
              <%= for deployment <- @sortie.deployments do %>
                <tr>
                  <td>
                    <div class="font-semibold">
                      {deployment.company_unit.custom_name || deployment.company_unit.master_unit.name}
                    </div>
                    <div class="text-xs opacity-70">
                      {deployment.company_unit.master_unit.variant}
                    </div>
                  </td>
                  <td>
                    <%= if deployment.pilot do %>
                      <div>{deployment.pilot.name}</div>
                      <%= if deployment.pilot.callsign do %>
                        <div class="text-xs opacity-70">"{deployment.pilot.callsign}"</div>
                      <% end %>
                    <% else %>
                      <span class="opacity-50">Unnamed crew</span>
                    <% end %>
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
                    <%= if (deployment.repair_cost_sp || 0) > 0 do %>
                      {deployment.repair_cost_sp} SP
                    <% else %>
                      —
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders pilot SP allocations showing what each pilot spent their earned SP on.
  """
  attr :allocations, :list, required: true

  def pilot_allocations(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">Pilot SP Allocations</h2>
        <div class="overflow-x-auto">
          <table class="table table-sm w-full">
            <thead>
              <tr>
                <th>Pilot</th>
                <th class="text-center">MVP</th>
                <th class="text-right">SP Earned</th>
                <th class="text-right">To Skill</th>
                <th class="text-right">To Edge Tokens</th>
                <th class="text-right">To Abilities</th>
                <th>Abilities Gained</th>
              </tr>
            </thead>
            <tbody>
              <%= for alloc <- @allocations do %>
                <tr>
                  <td>
                    <div class="font-semibold">{alloc.pilot_name}</div>
                    <%= if alloc.pilot_callsign do %>
                      <div class="text-xs opacity-70">"{alloc.pilot_callsign}"</div>
                    <% end %>
                  </td>
                  <td class="text-center">
                    <%= if alloc.is_mvp do %>
                      <span class="badge badge-warning badge-sm">MVP</span>
                    <% else %>
                      <span class="opacity-50">—</span>
                    <% end %>
                  </td>
                  <td class="text-right font-mono font-semibold">{alloc.total_sp} SP</td>
                  <td class="text-right font-mono">
                    <%= if alloc.sp_to_skill > 0 do %>
                      {alloc.sp_to_skill}
                    <% else %>
                      <span class="opacity-50">—</span>
                    <% end %>
                  </td>
                  <td class="text-right font-mono">
                    <%= if alloc.sp_to_tokens > 0 do %>
                      {alloc.sp_to_tokens}
                    <% else %>
                      <span class="opacity-50">—</span>
                    <% end %>
                  </td>
                  <td class="text-right font-mono">
                    <%= if alloc.sp_to_abilities > 0 do %>
                      {alloc.sp_to_abilities}
                    <% else %>
                      <span class="opacity-50">—</span>
                    <% end %>
                  </td>
                  <td>
                    <%= if length(alloc.edge_abilities_gained) > 0 do %>
                      <div class="flex flex-wrap gap-1">
                        <%= for ability <- alloc.edge_abilities_gained do %>
                          <span class="badge badge-accent badge-sm">{ability}</span>
                        <% end %>
                      </div>
                    <% else %>
                      <span class="opacity-50">—</span>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions

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
