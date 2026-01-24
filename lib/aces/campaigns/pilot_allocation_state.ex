defmodule Aces.Campaigns.PilotAllocationState do
  @moduledoc """
  Runtime state management for pilot SP allocation during sortie completion.

  This module manages the state and calculations for allocating earned SP
  to pilots across three pools: Skill, Edge Tokens, and Edge Abilities.

  The allocation tracks:
  - Baseline allocations: SP allocated before this sortie (locked, cannot be reduced)
  - Additional allocations: New SP being allocated this sortie
  - Edge abilities: Both previously selected (locked) and newly selected

  All functions in this module are pure calculations that don't interact
  with the database directly.

  Note: This module was renamed from PilotAllocation to PilotAllocationState
  to make room for the new PilotAllocation Ecto schema.
  """

  alias Aces.Companies.Pilot

  @type t :: %{
          pilot: Pilot.t(),
          baseline_skill: non_neg_integer(),
          baseline_tokens: non_neg_integer(),
          baseline_abilities: non_neg_integer(),
          baseline_edge_abilities: [String.t()],
          add_skill: non_neg_integer(),
          add_tokens: non_neg_integer(),
          add_abilities: non_neg_integer(),
          new_edge_abilities: [String.t()],
          sp_to_spend: non_neg_integer(),
          sp_remaining: integer(),
          skill_level: non_neg_integer(),
          edge_tokens: non_neg_integer(),
          max_abilities: non_neg_integer(),
          has_error: boolean()
        }

  @doc """
  Build a fresh allocation for a pilot who hasn't allocated SP yet this sortie.

  Takes a pilot struct and returns an allocation map with all baseline values
  set from the pilot's current state and zero additional allocations.

  ## Examples

      iex> build_fresh(pilot)
      %{pilot: pilot, baseline_skill: 0, add_skill: 0, sp_remaining: 50, ...}
  """
  @spec build_fresh(Pilot.t()) :: t()
  def build_fresh(pilot) do
    baseline_skill = pilot.sp_allocated_to_skill
    baseline_tokens = pilot.sp_allocated_to_edge_tokens
    baseline_abilities = pilot.sp_allocated_to_edge_abilities
    baseline_edge_abilities = pilot.edge_abilities || []

    %{
      pilot: pilot,
      # Baseline (locked) allocations from before this sortie
      baseline_skill: baseline_skill,
      baseline_tokens: baseline_tokens,
      baseline_abilities: baseline_abilities,
      baseline_edge_abilities: baseline_edge_abilities,
      # Additional SP to allocate (starts at 0)
      add_skill: 0,
      add_tokens: 0,
      add_abilities: 0,
      # New edge abilities selected this sortie
      new_edge_abilities: [],
      # SP available to spend this sortie
      sp_to_spend: pilot.sp_available,
      sp_remaining: pilot.sp_available,
      # Derived values
      skill_level: pilot.skill_level,
      edge_tokens: pilot.edge_tokens,
      max_abilities: Pilot.calculate_edge_abilities_from_sp(baseline_abilities),
      has_error: false
    }
  end

  @doc """
  Build an allocation from previously saved data.

  Restores allocation state from the saved map (stored in sortie.pilot_allocations)
  and recalculates derived values.

  ## Parameters
  - `pilot` - The pilot struct
  - `saved` - Map with string keys containing saved allocation data

  ## Examples

      iex> build_from_saved(pilot, %{"add_skill" => 100, "baseline_skill" => 0, ...})
      %{pilot: pilot, add_skill: 100, sp_remaining: 50, ...}
  """
  @spec build_from_saved(Pilot.t(), map()) :: t()
  def build_from_saved(pilot, saved) do
    # Restore baselines from saved data (these are the TRUE baselines from before this sortie)
    baseline_skill = saved["baseline_skill"] || 0
    baseline_tokens = saved["baseline_tokens"] || 0
    baseline_abilities = saved["baseline_abilities"] || 0
    baseline_edge_abilities = saved["baseline_edge_abilities"] || []

    # Restore the add values from saved data
    add_skill = saved["add_skill"] || 0
    add_tokens = saved["add_tokens"] || 0
    add_abilities = saved["add_abilities"] || 0
    new_edge_abilities = saved["new_edge_abilities"] || []

    # SP to spend is the sum of what was allocated
    sp_to_spend = saved["sp_to_spend"] || (add_skill + add_tokens + add_abilities)

    # Calculate derived values
    total_skill = baseline_skill + add_skill
    total_tokens = baseline_tokens + add_tokens
    total_abilities = baseline_abilities + add_abilities

    skill_level = Pilot.calculate_skill_from_sp(total_skill)
    edge_tokens = Pilot.calculate_edge_tokens_from_sp(total_tokens)
    max_abilities = Pilot.calculate_edge_abilities_from_sp(total_abilities)

    sp_remaining = sp_to_spend - add_skill - add_tokens - add_abilities

    %{
      pilot: pilot,
      baseline_skill: baseline_skill,
      baseline_tokens: baseline_tokens,
      baseline_abilities: baseline_abilities,
      baseline_edge_abilities: baseline_edge_abilities,
      add_skill: add_skill,
      add_tokens: add_tokens,
      add_abilities: add_abilities,
      new_edge_abilities: new_edge_abilities,
      sp_to_spend: sp_to_spend,
      sp_remaining: sp_remaining,
      skill_level: skill_level,
      edge_tokens: edge_tokens,
      max_abilities: max_abilities,
      has_error: sp_remaining < 0
    }
  end

  @doc """
  Build allocations for all pilots, using saved data when available.

  Returns a tuple of {pilots_with_sp, allocations_map} where:
  - `pilots_with_sp` - List of pilots who have SP to spend or saved allocations
  - `allocations_map` - Map of pilot_id => allocation

  ## Parameters
  - `all_pilots` - List of all company pilots
  - `saved_allocations` - Map from sortie.pilot_allocations (may be nil or empty)
  """
  @spec build_all(list(Pilot.t()), map() | nil) :: {list(Pilot.t()), map()}
  def build_all(all_pilots, saved_allocations) do
    saved_allocations = saved_allocations || %{}

    # Filter pilots who have SP to spend or have saved allocations
    pilots_with_sp =
      Enum.filter(all_pilots, fn pilot ->
        pilot_id_str = to_string(pilot.id)
        (pilot.sp_available || 0) > 0 or Map.has_key?(saved_allocations, pilot_id_str)
      end)

    # Build allocation state for each pilot
    allocations =
      pilots_with_sp
      |> Enum.map(fn pilot ->
        pilot_id_str = to_string(pilot.id)
        saved = Map.get(saved_allocations, pilot_id_str)

        if saved do
          {pilot.id, build_from_saved(pilot, saved)}
        else
          {pilot.id, build_fresh(pilot)}
        end
      end)
      |> Map.new()

    {pilots_with_sp, allocations}
  end

  @doc """
  Update an allocation field and recalculate derived values.

  Valid fields are: "skill", "edge_tokens", "edge_abilities"

  ## Parameters
  - `allocation` - The current allocation map
  - `field` - String field name to update
  - `value` - New value (will be clamped to >= 0)

  ## Examples

      iex> update_allocation(allocation, "skill", 100)
      %{...add_skill: 100, sp_remaining: -50, has_error: true, ...}
  """
  @spec update_allocation(t(), String.t(), integer()) :: t()
  def update_allocation(allocation, field, value) do
    # Clamp value to be non-negative
    value = max(0, value)

    # Update the specific field
    updated =
      case field do
        "skill" -> %{allocation | add_skill: value}
        "edge_tokens" -> %{allocation | add_tokens: value}
        "edge_abilities" -> %{allocation | add_abilities: value}
        _ -> allocation
      end

    recalculate_derived(updated)
  end

  @doc """
  Toggle an edge ability on or off.

  Rules:
  - Baseline abilities cannot be toggled off
  - New abilities can be toggled on/off
  - Cannot exceed max_abilities limit

  ## Parameters
  - `allocation` - The current allocation map
  - `ability` - String name of the ability to toggle

  ## Examples

      iex> toggle_edge_ability(allocation, "Accurate")
      %{...new_edge_abilities: ["Accurate"], ...}
  """
  @spec toggle_edge_ability(t(), String.t()) :: t()
  def toggle_edge_ability(allocation, ability) do
    # Calculate current max abilities based on total SP allocated to abilities
    total_abilities_sp = allocation.baseline_abilities + allocation.add_abilities
    max_allowed = Pilot.calculate_edge_abilities_from_sp(total_abilities_sp)

    # All current abilities = baseline + new
    all_current = allocation.baseline_edge_abilities ++ allocation.new_edge_abilities

    new_abilities =
      cond do
        # Can't remove baseline abilities
        ability in allocation.baseline_edge_abilities ->
          allocation.new_edge_abilities

        # Toggle off if already in new abilities
        ability in allocation.new_edge_abilities ->
          List.delete(allocation.new_edge_abilities, ability)

        # Add if we have room
        length(all_current) < max_allowed ->
          [ability | allocation.new_edge_abilities]

        # At max, can't add
        true ->
          allocation.new_edge_abilities
      end

    %{allocation | new_edge_abilities: new_abilities}
  end

  @doc """
  Validate an allocation is complete and has no errors.

  Returns `:ok` if valid, `{:error, reason}` otherwise.

  ## Examples

      iex> validate(%{sp_remaining: 0, has_error: false})
      :ok

      iex> validate(%{sp_remaining: 10, has_error: false})
      {:error, :sp_not_fully_spent}
  """
  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(allocation) do
    cond do
      allocation.has_error ->
        {:error, :overspent}

      allocation.sp_remaining != 0 ->
        {:error, :sp_not_fully_spent}

      true ->
        :ok
    end
  end

  @doc """
  Check if all allocations in a map are valid.

  ## Examples

      iex> all_valid?(%{1 => %{sp_remaining: 0, has_error: false}})
      true
  """
  @spec all_valid?(map()) :: boolean()
  def all_valid?(allocations) do
    Enum.all?(allocations, fn {_id, alloc} ->
      alloc.sp_remaining == 0 and not alloc.has_error
    end)
  end

  @doc """
  Check if any allocation has an error (overspent).
  """
  @spec any_errors?(map()) :: boolean()
  def any_errors?(allocations) do
    Enum.any?(allocations, fn {_id, alloc} -> alloc.has_error end)
  end

  @doc """
  Convert an allocation to a map suitable for saving to the sortie.

  This is the format stored in sortie.pilot_allocations.
  """
  @spec to_saved_format(t()) :: map()
  def to_saved_format(allocation) do
    %{
      "baseline_skill" => allocation.baseline_skill,
      "baseline_tokens" => allocation.baseline_tokens,
      "baseline_abilities" => allocation.baseline_abilities,
      "baseline_edge_abilities" => allocation.baseline_edge_abilities,
      "add_skill" => allocation.add_skill,
      "add_tokens" => allocation.add_tokens,
      "add_abilities" => allocation.add_abilities,
      "new_edge_abilities" => allocation.new_edge_abilities,
      "sp_to_spend" => allocation.sp_to_spend
    }
  end

  @doc """
  Convert all allocations to the saved format for sortie.pilot_allocations.
  """
  @spec all_to_saved_format(map()) :: map()
  def all_to_saved_format(allocations) do
    allocations
    |> Enum.map(fn {pilot_id, alloc} ->
      {to_string(pilot_id), to_saved_format(alloc)}
    end)
    |> Map.new()
  end

  @doc """
  Build the changes map needed to update a pilot's record after SP allocation.

  Returns a map with all the fields that need to be updated on the pilot.
  """
  @spec to_pilot_changes(t()) :: map()
  def to_pilot_changes(allocation) do
    # Calculate final totals
    total_skill = allocation.baseline_skill + allocation.add_skill
    total_tokens = allocation.baseline_tokens + allocation.add_tokens
    total_abilities = allocation.baseline_abilities + allocation.add_abilities
    all_abilities = allocation.baseline_edge_abilities ++ allocation.new_edge_abilities

    %{
      sp_allocated_to_skill: total_skill,
      sp_allocated_to_edge_tokens: total_tokens,
      sp_allocated_to_edge_abilities: total_abilities,
      edge_abilities: all_abilities,
      skill_level: Pilot.calculate_skill_from_sp(total_skill),
      edge_tokens: Pilot.calculate_edge_tokens_from_sp(total_tokens),
      sp_available: 0
    }
  end

  @doc """
  Get the total count of all edge abilities (baseline + new).
  """
  @spec total_abilities_count(t()) :: non_neg_integer()
  def total_abilities_count(allocation) do
    length(allocation.baseline_edge_abilities) + length(allocation.new_edge_abilities)
  end

  # Private functions

  defp recalculate_derived(allocation) do
    # Recalculate sp_remaining
    total_added = allocation.add_skill + allocation.add_tokens + allocation.add_abilities
    sp_remaining = allocation.sp_to_spend - total_added

    # Recalculate derived values based on total SP (baseline + additional)
    total_skill = allocation.baseline_skill + allocation.add_skill
    total_tokens = allocation.baseline_tokens + allocation.add_tokens
    total_abilities = allocation.baseline_abilities + allocation.add_abilities

    skill_level = Pilot.calculate_skill_from_sp(total_skill)
    edge_tokens = Pilot.calculate_edge_tokens_from_sp(total_tokens)
    max_abilities = Pilot.calculate_edge_abilities_from_sp(total_abilities)

    # Trim new edge abilities if max reduced
    baseline_count = length(allocation.baseline_edge_abilities)
    available_new_slots = max(0, max_abilities - baseline_count)
    trimmed_new_abilities = Enum.take(allocation.new_edge_abilities, available_new_slots)

    has_error = sp_remaining < 0

    %{
      allocation
      | sp_remaining: sp_remaining,
        skill_level: skill_level,
        edge_tokens: edge_tokens,
        max_abilities: max_abilities,
        new_edge_abilities: trimmed_new_abilities,
        has_error: has_error
    }
  end
end
