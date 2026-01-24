defmodule Aces.Repo.Migrations.MigratePilotAllocationsData do
  @moduledoc """
  Data migration that moves pilot allocation data from the JSON `pilot_allocations`
  column on sorties to the new `pilot_allocations` table.

  This migration:
  1. Creates "initial" allocation records from the baseline values of each pilot's
     first sortie allocation (representing their pre-sortie SP state)
  2. Creates "sortie" allocation records from the add_* values of each sortie
  3. Creates "initial" allocations for pilots who have SP allocated but haven't
     participated in any sorties yet

  The migration is reversible - the down migration deletes all pilot_allocations records.
  """
  use Ecto.Migration
  import Ecto.Query

  def up do
    # Ensure previous migrations are applied
    flush()

    # Track which pilots we've created initial allocations for
    pilots_with_initial = migrate_existing_sortie_allocations()

    # Create initial allocations for pilots who have SP allocated but no sorties
    create_initial_allocations_for_remaining_pilots(pilots_with_initial)
  end

  def down do
    # Delete all pilot_allocations (reversible)
    execute("DELETE FROM pilot_allocations")
  end

  # Migrate data from sorties.pilot_allocations JSON column
  defp migrate_existing_sortie_allocations do
    # Query all sorties with non-empty pilot_allocations
    sorties =
      repo().all(
        from(s in "sorties",
          where: not is_nil(s.pilot_allocations),
          select: %{
            id: s.id,
            pilot_allocations: s.pilot_allocations,
            inserted_at: s.inserted_at
          },
          order_by: [asc: s.inserted_at]
        )
      )

    # Track which pilots we've created initial allocations for
    Enum.reduce(sorties, MapSet.new(), fn sortie, pilots_with_initial ->
      # pilot_allocations is stored as JSON with string keys like "10" => %{...}
      allocations = sortie.pilot_allocations || %{}

      Enum.reduce(allocations, pilots_with_initial, fn {pilot_id_str, alloc}, acc ->
        pilot_id = parse_pilot_id(pilot_id_str)

        if is_nil(pilot_id) do
          acc
        else
          # Create initial allocation from baseline (first time we see this pilot)
          acc =
            if pilot_id not in acc do
              create_initial_allocation_from_baseline(pilot_id, alloc, sortie.inserted_at)
              MapSet.put(acc, pilot_id)
            else
              acc
            end

          # Create sortie allocation from add_* values
          create_sortie_allocation(pilot_id, sortie.id, alloc, sortie.inserted_at)

          acc
        end
      end)
    end)
  end

  defp parse_pilot_id(pilot_id_str) when is_binary(pilot_id_str) do
    case Integer.parse(pilot_id_str) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_pilot_id(pilot_id) when is_integer(pilot_id), do: pilot_id
  defp parse_pilot_id(_), do: nil

  defp create_initial_allocation_from_baseline(pilot_id, alloc, timestamp) do
    # baseline values represent state before this sortie = initial allocation
    sp_to_skill = get_int(alloc, "baseline_skill")
    sp_to_tokens = get_int(alloc, "baseline_tokens")
    sp_to_abilities = get_int(alloc, "baseline_abilities")
    total_sp = sp_to_skill + sp_to_tokens + sp_to_abilities

    edge_abilities = get_list(alloc, "baseline_edge_abilities")

    repo().insert_all("pilot_allocations", [
      %{
        pilot_id: pilot_id,
        sortie_id: nil,
        allocation_type: "initial",
        sp_to_skill: sp_to_skill,
        sp_to_tokens: sp_to_tokens,
        sp_to_abilities: sp_to_abilities,
        edge_abilities_gained: edge_abilities,
        total_sp: total_sp,
        inserted_at: timestamp,
        updated_at: timestamp
      }
    ])
  end

  defp create_sortie_allocation(pilot_id, sortie_id, alloc, timestamp) do
    sp_to_skill = get_int(alloc, "add_skill")
    sp_to_tokens = get_int(alloc, "add_tokens")
    sp_to_abilities = get_int(alloc, "add_abilities")

    # For sortie allocations, total_sp should match sp_to_spend
    # (the amount earned this sortie), not the sum of allocations
    total_sp = get_int(alloc, "sp_to_spend")

    edge_abilities = get_list(alloc, "new_edge_abilities")

    repo().insert_all("pilot_allocations", [
      %{
        pilot_id: pilot_id,
        sortie_id: sortie_id,
        allocation_type: "sortie",
        sp_to_skill: sp_to_skill,
        sp_to_tokens: sp_to_tokens,
        sp_to_abilities: sp_to_abilities,
        edge_abilities_gained: edge_abilities,
        total_sp: total_sp,
        inserted_at: timestamp,
        updated_at: timestamp
      }
    ])
  end

  defp create_initial_allocations_for_remaining_pilots(pilots_with_initial) do
    # Find pilots who have SP allocated but no allocation records yet
    # These are pilots who were created and allocated SP outside of sorties
    existing_pilot_ids =
      if MapSet.size(pilots_with_initial) > 0 do
        MapSet.to_list(pilots_with_initial)
      else
        # If no pilots have allocations yet, get from the table
        repo().all(
          from(a in "pilot_allocations",
            select: a.pilot_id,
            distinct: true
          )
        )
      end

    # Query pilots who:
    # 1. Don't have any allocation records yet
    # 2. Have SP allocated (meaning they've spent some of their starting 150 SP)
    pilots_needing_initial =
      repo().all(
        from(p in "pilots",
          where: p.id not in ^existing_pilot_ids,
          where:
            p.sp_allocated_to_skill > 0 or
              p.sp_allocated_to_edge_tokens > 0 or
              p.sp_allocated_to_edge_abilities > 0,
          select: %{
            id: p.id,
            sp_to_skill: p.sp_allocated_to_skill,
            sp_to_tokens: p.sp_allocated_to_edge_tokens,
            sp_to_abilities: p.sp_allocated_to_edge_abilities,
            edge_abilities: p.edge_abilities,
            inserted_at: p.inserted_at
          }
        )
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    records =
      Enum.map(pilots_needing_initial, fn p ->
        sp_to_skill = p.sp_to_skill || 0
        sp_to_tokens = p.sp_to_tokens || 0
        sp_to_abilities = p.sp_to_abilities || 0

        %{
          pilot_id: p.id,
          sortie_id: nil,
          allocation_type: "initial",
          sp_to_skill: sp_to_skill,
          sp_to_tokens: sp_to_tokens,
          sp_to_abilities: sp_to_abilities,
          edge_abilities_gained: p.edge_abilities || [],
          total_sp: sp_to_skill + sp_to_tokens + sp_to_abilities,
          inserted_at: p.inserted_at || now,
          updated_at: now
        }
      end)

    if records != [] do
      repo().insert_all("pilot_allocations", records)
    end
  end

  # Helper to safely get integer values from map (handles both string and atom keys)
  defp get_int(map, key) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, String.to_atom(key)) || 0

    case value do
      v when is_integer(v) -> v
      v when is_binary(v) -> String.to_integer(v)
      _ -> 0
    end
  end

  # Helper to safely get list values from map
  defp get_list(map, key) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, String.to_atom(key)) || []

    case value do
      v when is_list(v) -> v
      _ -> []
    end
  end
end
