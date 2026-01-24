defmodule Aces.Campaigns.SortieCompletion do
  @moduledoc """
  Business logic for sortie completion workflow.

  This module contains pure business logic for:
  - Calculating operational costs (repair, rearming, casualty)
  - Calculating pilot earnings based on participation
  - Reversing pilot allocations when costs change
  - Distributing SP to pilots after a sortie

  All functions in this module are pure calculations that don't interact
  with the database directly. They return data structures that can be
  used by LiveViews or other modules to perform the actual updates.
  """

  alias Aces.Campaigns.{Sortie, Deployment}
  alias Aces.Companies.Pilot

  @mvp_bonus_sp 20
  @casualty_cost_sp 100

  @doc """
  Calculate all operational costs for a sortie based on its deployments.

  Returns a map with:
  - `repair_costs` - map of deployment_id => repair cost
  - `rearming_costs` - map of deployment_id => rearming cost
  - `casualty_costs` - map of deployment_id => casualty cost
  - `total_repair` - sum of all repair costs
  - `total_rearming` - sum of all rearming costs
  - `total_casualty` - sum of all casualty costs
  - `total_expenses` - sum of all operational expenses
  - `base_income` - raw income before modifier
  - `adjusted_income` - income after reward modifier
  - `net_earnings` - adjusted income minus total expenses

  ## Examples

      iex> calculate_all_costs(sortie)
      %{repair_costs: %{1 => 60, 2 => 0}, total_expenses: 180, ...}
  """
  def calculate_all_costs(%Sortie{} = sortie) do
    deployments = sortie.deployments

    repair_costs = calculate_repair_costs(deployments)
    rearming_costs = calculate_rearming_costs(deployments)
    casualty_costs = calculate_casualty_costs(deployments)

    total_repair = sum_costs(repair_costs)
    total_rearming = sum_costs(rearming_costs)
    total_casualty = sum_costs(casualty_costs)
    total_expenses = total_repair + total_rearming + total_casualty

    base_income = calculate_base_income(sortie)
    adjusted_income = calculate_adjusted_income(base_income, sortie.campaign.reward_modifier)
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

  @doc """
  Calculate pilot earnings for all pilots based on sortie results.

  Pilots earn SP based on:
  - Participation: Full share for participants, half share for non-participants
  - Status: Killed pilots earn nothing, deceased pilots are excluded
  - Pool constraint: If net earnings is insufficient, all earnings are scaled down

  Returns a map of pilot_id => %{sp: integer, status: atom, participated: boolean}

  ## Examples

      iex> calculate_pilot_earnings(sortie, all_pilots, participating_pilot_ids)
      %{1 => %{sp: 50, status: :active, participated: true}, ...}
  """
  def calculate_pilot_earnings(%Sortie{} = sortie, all_pilots, participating_pilot_ids) do
    net_earnings = sortie.net_earnings || 0
    max_sp_per_pilot = sortie.sp_per_participating_pilot || 0
    killed_pilot_ids = get_killed_pilot_ids(sortie)

    # First pass: calculate "desired" SP for each pilot
    desired_earnings = calculate_desired_earnings(
      all_pilots,
      participating_pilot_ids,
      killed_pilot_ids,
      max_sp_per_pilot
    )

    # Calculate total desired and scale factor
    total_desired = sum_desired_sp(desired_earnings)
    scale_factor = calculate_scale_factor(net_earnings, total_desired)

    # Second pass: apply scale factor to get actual SP
    apply_scale_factor(desired_earnings, scale_factor)
  end

  @doc """
  Reverse pilot allocations made during the spend_sp step.

  This is called when:
  - MVP changes after SP has been distributed
  - Costs change after pilots have allocated their SP

  Returns a list of {pilot_id, changes_map} tuples that need to be applied.

  ## Parameters
  - `pilot_allocations` - saved allocations from sortie.pilot_allocations
  - `all_pilots` - list of all company pilots

  ## Examples

      iex> reverse_pilot_allocations(allocations, pilots)
      [{1, %{sp_allocated_to_skill: 0, skill_level: 4, ...}}, ...]
  """
  def reverse_pilot_allocations(nil, _pilots), do: []
  def reverse_pilot_allocations(allocations, _pilots) when allocations == %{}, do: []
  def reverse_pilot_allocations(allocations, pilots) do
    Enum.flat_map(allocations, fn {pilot_id_str, saved} ->
      pilot_id = String.to_integer(pilot_id_str)
      pilot = Enum.find(pilots, &(&1.id == pilot_id))

      if pilot do
        changes = build_reversal_changes(saved)
        [{pilot_id, changes}]
      else
        []
      end
    end)
  end

  @doc """
  Build the changes needed for a full pilot allocation reversal,
  including SP earned and sortie participation counts.

  This is used when costs change significantly and all pilot distributions
  need to be rolled back completely.

  ## Parameters
  - `pilot_allocations` - saved allocations from sortie.pilot_allocations
  - `all_pilots` - list of all company pilots
  - `sortie` - the sortie being modified

  Returns a list of {pilot_id, changes_map} tuples.
  """
  def reverse_pilot_allocations_full(nil, _pilots, _sortie), do: []
  def reverse_pilot_allocations_full(allocations, _pilots, _sortie) when allocations == %{}, do: []
  def reverse_pilot_allocations_full(allocations, pilots, sortie) do
    Enum.flat_map(allocations, fn {pilot_id_str, saved} ->
      pilot_id = String.to_integer(pilot_id_str)
      pilot = Enum.find(pilots, &(&1.id == pilot_id))

      if pilot do
        changes = build_full_reversal_changes(pilot, saved, sortie, pilot_id)
        [{pilot_id, changes}]
      else
        []
      end
    end)
  end

  @doc """
  Calculate the SP distribution for all pilots.

  This function computes what changes need to be made to each pilot's
  SP and participation stats when distributing sortie earnings.

  Returns:
  - `total_pilot_sp_cost` - total SP being distributed to pilots
  - `pilot_changes` - list of {pilot_id, changes_map} tuples

  ## Parameters
  - `all_pilots` - list of all company pilots
  - `pilot_earnings` - map from calculate_pilot_earnings/3
  - `mvp_id` - pilot ID of the MVP (or nil)
  """
  def distribute_sp_to_pilots(all_pilots, pilot_earnings, mvp_id) do
    total_pilot_sp_cost =
      Enum.reduce(all_pilots, 0, fn pilot, acc ->
        earnings = Map.get(pilot_earnings, pilot.id)
        if earnings && earnings.sp > 0 do
          acc + earnings.sp
        else
          acc
        end
      end)

    pilot_changes =
      Enum.flat_map(all_pilots, fn pilot ->
        earnings = Map.get(pilot_earnings, pilot.id)
        build_pilot_distribution_changes(pilot, earnings, mvp_id)
      end)

    %{
      total_pilot_sp_cost: total_pilot_sp_cost,
      pilot_changes: pilot_changes
    }
  end

  @doc """
  Build casualty status updates for pilots based on deployment outcomes.

  Returns a list of {pilot_id, changes_map} tuples for wounded/killed pilots.
  """
  def build_casualty_updates(deployments) do
    Enum.flat_map(deployments, fn deployment ->
      if deployment.pilot_id do
        case deployment.pilot_casualty do
          "wounded" ->
            [{deployment.pilot_id, %{status: "wounded"}}]
          "killed" ->
            [{deployment.pilot_id, %{status: "deceased"}}]
          _ ->
            []
        end
      else
        []
      end
    end)
  end

  @doc """
  Calculate changes needed when MVP changes after SP distribution.

  Returns:
  - `old_mvp_changes` - changes to apply to old MVP (if any)
  - `new_mvp_changes` - changes to apply to new MVP (if any)
  """
  def calculate_mvp_change(old_mvp_id, new_mvp_id, _all_pilots) when old_mvp_id == new_mvp_id do
    %{old_mvp_changes: nil, new_mvp_changes: nil}
  end
  def calculate_mvp_change(old_mvp_id, new_mvp_id, all_pilots) do
    old_mvp_changes =
      if old_mvp_id do
        old_mvp = Enum.find(all_pilots, &(&1.id == old_mvp_id))
        if old_mvp do
          %{
            sp_earned: max((old_mvp.sp_earned || 0) - @mvp_bonus_sp, 0),
            sp_available: max((old_mvp.sp_available || 0) - @mvp_bonus_sp, 0),
            mvp_awards: max((old_mvp.mvp_awards || 0) - 1, 0)
          }
        end
      end

    new_mvp_changes =
      if new_mvp_id do
        new_mvp = Enum.find(all_pilots, &(&1.id == new_mvp_id))
        if new_mvp do
          %{
            sp_earned: (new_mvp.sp_earned || 0) + @mvp_bonus_sp,
            sp_available: (new_mvp.sp_available || 0) + @mvp_bonus_sp,
            mvp_awards: (new_mvp.mvp_awards || 0) + 1
          }
        end
      end

    %{old_mvp_changes: old_mvp_changes, new_mvp_changes: new_mvp_changes}
  end

  @doc """
  Determine the effective damage status for repair cost calculations.
  A destroyed unit that was salvaged is treated as "salvageable".
  """
  def effective_damage_status(%{damage_status: "destroyed", was_salvaged: true}), do: "salvageable"
  def effective_damage_status(%{damage_status: status}), do: status

  @doc """
  Check if operational costs have changed since last save.
  Returns true if the costs step needs to reset pilot allocations.
  """
  def costs_changed?(%Sortie{} = sortie, new_total_expenses) do
    old_operational_expenses = (sortie.total_expenses || 0) - (sortie.pilot_sp_cost || 0)
    old_operational_expenses != new_total_expenses
  end

  @doc """
  Returns the MVP bonus SP amount.
  """
  def mvp_bonus_sp, do: @mvp_bonus_sp

  @doc """
  Returns the casualty cost SP amount.
  """
  def casualty_cost_sp, do: @casualty_cost_sp

  # Private functions

  defp calculate_repair_costs(deployments) do
    Enum.map(deployments, fn d ->
      effective_status = effective_damage_status(d)
      repair_cost = Deployment.calculate_unit_repair_cost(d.company_unit.master_unit, effective_status)
      {d.id, repair_cost}
    end)
    |> Map.new()
  end

  defp calculate_rearming_costs(deployments) do
    Enum.map(deployments, fn d ->
      cost = Deployment.get_rearming_cost(d)
      {d.id, cost}
    end)
    |> Map.new()
  end

  defp calculate_casualty_costs(deployments) do
    Enum.map(deployments, fn d ->
      cost = if d.pilot_casualty in ["wounded", "killed"], do: @casualty_cost_sp, else: 0
      {d.id, cost}
    end)
    |> Map.new()
  end

  defp sum_costs(costs_map) do
    Enum.sum(Map.values(costs_map))
  end

  defp calculate_base_income(sortie) do
    (sortie.primary_objective_income || 0) +
      (sortie.secondary_objectives_income || 0) +
      (sortie.waypoints_income || 0) -
      (sortie.recon_total_cost || 0)
  end

  defp calculate_adjusted_income(base_income, reward_modifier) do
    round(base_income * reward_modifier)
  end

  defp get_killed_pilot_ids(%Sortie{deployments: deployments}) do
    deployments
    |> Enum.filter(&(&1.pilot_casualty == "killed" && &1.pilot_id))
    |> Enum.map(& &1.pilot_id)
    |> MapSet.new()
  end

  defp calculate_desired_earnings(all_pilots, participating_pilot_ids, killed_pilot_ids, max_sp_per_pilot) do
    Enum.map(all_pilots, fn pilot ->
      cond do
        MapSet.member?(killed_pilot_ids, pilot.id) ->
          {pilot.id, %{desired_sp: 0, status: :killed, participated: true}}

        pilot.status == "deceased" ->
          {pilot.id, %{desired_sp: 0, status: :deceased, participated: false}}

        MapSet.member?(participating_pilot_ids, pilot.id) ->
          {pilot.id, %{desired_sp: max_sp_per_pilot, status: :active, participated: true}}

        true ->
          {pilot.id, %{desired_sp: div(max_sp_per_pilot, 2), status: :active, participated: false}}
      end
    end)
  end

  defp sum_desired_sp(desired_earnings) do
    Enum.reduce(desired_earnings, 0, fn {_id, data}, acc -> acc + data.desired_sp end)
  end

  defp calculate_scale_factor(net_earnings, total_desired) do
    cond do
      net_earnings <= 0 -> 0.0
      total_desired <= net_earnings -> 1.0
      total_desired > 0 -> net_earnings / total_desired
      true -> 0.0
    end
  end

  defp apply_scale_factor(desired_earnings, scale_factor) do
    Enum.map(desired_earnings, fn {pilot_id, data} ->
      actual_sp =
        if data.desired_sp > 0 do
          floor(data.desired_sp * scale_factor)
        else
          0
        end

      {pilot_id, %{sp: actual_sp, status: data.status, participated: data.participated}}
    end)
    |> Map.new()
  end

  defp build_reversal_changes(saved) do
    baseline_skill = saved["baseline_skill"] || 0
    baseline_tokens = saved["baseline_tokens"] || 0
    baseline_abilities = saved["baseline_abilities"] || 0
    baseline_edge_abilities = saved["baseline_edge_abilities"] || []
    sp_to_spend = saved["sp_to_spend"] || 0

    %{
      sp_allocated_to_skill: baseline_skill,
      sp_allocated_to_edge_tokens: baseline_tokens,
      sp_allocated_to_edge_abilities: baseline_abilities,
      edge_abilities: baseline_edge_abilities,
      skill_level: Pilot.calculate_skill_from_sp(baseline_skill),
      edge_tokens: Pilot.calculate_edge_tokens_from_sp(baseline_tokens),
      sp_available: sp_to_spend
    }
  end

  defp build_full_reversal_changes(pilot, saved, sortie, pilot_id) do
    baseline_skill = saved["baseline_skill"] || 0
    baseline_tokens = saved["baseline_tokens"] || 0
    baseline_abilities = saved["baseline_abilities"] || 0
    baseline_edge_abilities = saved["baseline_edge_abilities"] || []
    sp_received = saved["sp_to_spend"] || 0

    mvp_bonus = if sortie.mvp_pilot_id == pilot_id, do: @mvp_bonus_sp, else: 0
    total_sp_to_remove = sp_received + mvp_bonus

    %{
      sp_allocated_to_skill: baseline_skill,
      sp_allocated_to_edge_tokens: baseline_tokens,
      sp_allocated_to_edge_abilities: baseline_abilities,
      edge_abilities: baseline_edge_abilities,
      skill_level: Pilot.calculate_skill_from_sp(baseline_skill),
      edge_tokens: Pilot.calculate_edge_tokens_from_sp(baseline_tokens),
      sp_available: 0,
      sp_earned: max((pilot.sp_earned || 0) - total_sp_to_remove, 0),
      sorties_participated: max((pilot.sorties_participated || 0) - 1, 0),
      mvp_awards: if(sortie.mvp_pilot_id == pilot_id, do: max((pilot.mvp_awards || 0) - 1, 0), else: pilot.mvp_awards)
    }
  end

  defp build_pilot_distribution_changes(pilot, earnings, mvp_id) do
    base_sp = if earnings && earnings.sp > 0, do: earnings.sp, else: 0

    is_mvp = pilot.id == mvp_id
    mvp_bonus = if is_mvp && earnings && earnings.participated && earnings.status == :active, do: @mvp_bonus_sp, else: 0

    total_sp = base_sp + mvp_bonus

    if total_sp > 0 || (earnings && earnings.participated) do
      new_sp_earned = (pilot.sp_earned || 0) + total_sp
      new_sp_available = (pilot.sp_available || 0) + total_sp
      new_sorties = (pilot.sorties_participated || 0) + if(earnings && earnings.participated, do: 1, else: 0)
      new_mvp_awards = (pilot.mvp_awards || 0) + if(is_mvp && mvp_bonus > 0, do: 1, else: 0)

      [{pilot.id, %{
        sp_earned: new_sp_earned,
        sp_available: new_sp_available,
        sorties_participated: new_sorties,
        mvp_awards: new_mvp_awards
      }}]
    else
      []
    end
  end
end
