# Pilot Allocations Migration Plan

## Overview

This document describes the migration from storing pilot SP allocations as a JSON map on the `sorties` table to a dedicated `pilot_allocations` table. This change provides:

1. **Full database validation** - Ecto schema with proper constraints
2. **Unified allocation history** - Both initial (150 SP) and sortie allocations in one place
3. **Audit trail** - Complete history of how each pilot's stats evolved
4. **Type safety** - Compile-time validation via Ecto schema

## Current State

### How Allocations Work Today

1. **Pilot Creation**: Pilots are created with `sp_available = 150`. The current UI doesn't enforce immediate allocation.

2. **Sortie Completion**: During the "Spend SP" step of sortie completion:
   - Pilots earn SP based on participation
   - They allocate SP to three pools: Skill, Edge Tokens, Edge Abilities
   - They can select Edge Abilities up to their unlocked limit
   - Allocations are saved to `sorties.pilot_allocations` as JSON

3. **Data Storage**: The `sorties.pilot_allocations` column stores a JSON map:
```elixir
%{
  "10" => %{  # pilot_id as string key
    "baseline_skill" => 40,        # SP allocated to skill BEFORE this sortie
    "baseline_tokens" => 150,      # SP allocated to tokens BEFORE this sortie
    "baseline_abilities" => 180,   # SP allocated to abilities BEFORE this sortie
    "baseline_edge_abilities" => ["Assassin"],  # Abilities BEFORE this sortie
    "add_skill" => 70,             # SP added to skill THIS sortie
    "add_tokens" => 0,             # SP added to tokens THIS sortie
    "add_abilities" => 0,          # SP added to abilities THIS sortie
    "new_edge_abilities" => [],    # Abilities gained THIS sortie
    "sp_to_spend" => 70            # Total SP earned this sortie
  },
  "11" => %{...},
  ...
}
```

### Current Files

| File | Purpose |
|------|---------|
| `lib/aces/campaigns/sortie.ex` | Has `pilot_allocations` as `:map` field |
| `lib/aces/campaigns/pilot_allocation.ex` | Runtime state management for spend_sp wizard |
| `lib/aces_web/live/sortie_live/complete/spend_sp.ex` | LiveView for SP allocation during sortie completion |
| `lib/aces/campaigns/sortie_completion.ex` | Business logic including `reverse_pilot_allocations/2` |
| `lib/aces/companies/pilot.ex` | Pilot schema with aggregated SP values |

### Existing Data

There is existing data in the database. Query to check:
```elixir
import Ecto.Query
Aces.Repo.all(from s in "sorties", where: not is_nil(s.pilot_allocations), select: s.pilot_allocations)
```

As of writing, there are ~6 sorties with allocation data that must be migrated.

## Target State

### New Database Schema

**Table: `pilot_allocations`**

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigint | PK | Primary key |
| `pilot_id` | bigint | FK, NOT NULL, indexed | Reference to pilots table |
| `sortie_id` | bigint | FK, nullable, indexed | Reference to sorties table (null for initial allocation) |
| `allocation_type` | string | NOT NULL | "initial" or "sortie" |
| `sp_to_skill` | integer | NOT NULL, >= 0 | SP allocated to skill in this allocation |
| `sp_to_tokens` | integer | NOT NULL, >= 0 | SP allocated to edge tokens |
| `sp_to_abilities` | integer | NOT NULL, >= 0 | SP allocated to edge abilities |
| `edge_abilities_gained` | string[] | NOT NULL, default [] | Edge abilities selected in this allocation |
| `total_sp` | integer | NOT NULL, >= 0 | Total SP in this allocation (sum of above 3) |
| `inserted_at` | utc_datetime | NOT NULL | Created timestamp |
| `updated_at` | utc_datetime | NOT NULL | Updated timestamp |

**Constraints:**
- Unique index on `[sortie_id, pilot_id]` where `sortie_id IS NOT NULL`
- Each pilot can have at most one "initial" allocation (unique where `allocation_type = 'initial'`)
- Foreign key cascade: if pilot deleted, delete their allocations
- Foreign key cascade: if sortie deleted, delete associated allocations

### New Ecto Schema

**File: `lib/aces/campaigns/pilot_allocation.ex`**

```elixir
defmodule Aces.Campaigns.PilotAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @allocation_types ~w(initial sortie)

  schema "pilot_allocations" do
    field :allocation_type, :string
    field :sp_to_skill, :integer, default: 0
    field :sp_to_tokens, :integer, default: 0
    field :sp_to_abilities, :integer, default: 0
    field :edge_abilities_gained, {:array, :string}, default: []
    field :total_sp, :integer, default: 0

    belongs_to :pilot, Aces.Companies.Pilot
    belongs_to :sortie, Aces.Campaigns.Sortie

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:allocation_type, :sp_to_skill, :sp_to_tokens, :sp_to_abilities,
                    :edge_abilities_gained, :total_sp, :pilot_id, :sortie_id])
    |> validate_required([:allocation_type, :pilot_id])
    |> validate_inclusion(:allocation_type, @allocation_types)
    |> validate_number(:sp_to_skill, greater_than_or_equal_to: 0)
    |> validate_number(:sp_to_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:sp_to_abilities, greater_than_or_equal_to: 0)
    |> validate_number(:total_sp, greater_than_or_equal_to: 0)
    |> validate_total_sp_sum()
    |> validate_sortie_required_for_sortie_type()
    |> validate_edge_abilities()
    |> foreign_key_constraint(:pilot_id)
    |> foreign_key_constraint(:sortie_id)
    |> unique_constraint([:sortie_id, :pilot_id])
  end

  # Validations...
end
```

### Computing Pilot State

A pilot's current state is computed by summing all their allocations:

```elixir
def compute_pilot_totals(pilot_id) do
  import Ecto.Query

  Repo.one(
    from a in PilotAllocation,
    where: a.pilot_id == ^pilot_id,
    select: %{
      sp_allocated_to_skill: sum(a.sp_to_skill),
      sp_allocated_to_edge_tokens: sum(a.sp_to_tokens),
      sp_allocated_to_edge_abilities: sum(a.sp_to_abilities)
    }
  )
end
```

Edge abilities are the concatenation of all `edge_abilities_gained` arrays.

**Denormalization**: Keep aggregated values on `Pilot` for performance. Update them whenever allocations change.

### Relationship Changes

**Sortie schema** (`lib/aces/campaigns/sortie.ex`):
```elixir
# Remove:
field :pilot_allocations, :map, default: %{}

# Add:
has_many :pilot_allocations, Aces.Campaigns.PilotAllocation
```

**Pilot schema** (`lib/aces/companies/pilot.ex`):
```elixir
# Add:
has_many :allocations, Aces.Campaigns.PilotAllocation
```

## Implementation Steps

### Phase 1: Preparation

#### Step 1.1: Rename Current Module
Rename the existing runtime state module to avoid naming conflicts:

- Rename `lib/aces/campaigns/pilot_allocation.ex` → `lib/aces/campaigns/pilot_allocation_state.ex`
- Rename module `Aces.Campaigns.PilotAllocation` → `Aces.Campaigns.PilotAllocationState`
- Update `lib/aces_web/live/sortie_live/complete/spend_sp.ex` to use `PilotAllocationState`
- Update `test/aces/campaigns/pilot_allocation_test.exs` → `pilot_allocation_state_test.exs`
- Run tests to verify nothing broke

#### Step 1.2: Create New Schema and Migration

Create migration:
```bash
mix ecto.gen.migration create_pilot_allocations
```

Migration content:
```elixir
defmodule Aces.Repo.Migrations.CreatePilotAllocations do
  use Ecto.Migration

  def change do
    create table(:pilot_allocations) do
      add :pilot_id, references(:pilots, on_delete: :delete_all), null: false
      add :sortie_id, references(:sorties, on_delete: :delete_all)
      add :allocation_type, :string, null: false
      add :sp_to_skill, :integer, null: false, default: 0
      add :sp_to_tokens, :integer, null: false, default: 0
      add :sp_to_abilities, :integer, null: false, default: 0
      add :edge_abilities_gained, {:array, :string}, null: false, default: []
      add :total_sp, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:pilot_allocations, [:pilot_id])
    create index(:pilot_allocations, [:sortie_id])
    create unique_index(:pilot_allocations, [:sortie_id, :pilot_id],
                        where: "sortie_id IS NOT NULL",
                        name: :pilot_allocations_sortie_pilot_unique)
    create unique_index(:pilot_allocations, [:pilot_id],
                        where: "allocation_type = 'initial'",
                        name: :pilot_allocations_initial_unique)
  end
end
```

Create the new schema file: `lib/aces/campaigns/pilot_allocation.ex`

### Phase 2: Data Migration

#### Step 2.1: Create Data Migration Script

Create migration to move existing data:
```bash
mix ecto.gen.migration migrate_pilot_allocations_data
```

```elixir
defmodule Aces.Repo.Migrations.MigratePilotAllocationsData do
  use Ecto.Migration
  import Ecto.Query

  def up do
    # This migration reads existing data and creates new records
    # Run with Mix.Task or execute/1 for complex logic

    flush()  # Ensure previous migrations are applied

    migrate_existing_allocations()
    create_initial_allocations_for_pilots_without_sorties()
  end

  def down do
    # Delete all pilot_allocations (reversible)
    execute("DELETE FROM pilot_allocations")
  end

  defp migrate_existing_allocations do
    # Get all sorties with pilot_allocations
    sorties = repo().all(
      from s in "sorties",
      where: not is_nil(s.pilot_allocations) and s.pilot_allocations != ^%{},
      select: %{id: s.id, pilot_allocations: s.pilot_allocations, inserted_at: s.inserted_at}
    )

    # Track which pilots we've created initial allocations for
    pilots_with_initial = MapSet.new()

    for sortie <- sorties do
      for {pilot_id_str, alloc} <- sortie.pilot_allocations do
        pilot_id = String.to_integer(pilot_id_str)

        # Create initial allocation from baseline (first time we see this pilot)
        pilots_with_initial =
          if pilot_id not in pilots_with_initial do
            create_initial_allocation(pilot_id, alloc, sortie.inserted_at)
            MapSet.put(pilots_with_initial, pilot_id)
          else
            pilots_with_initial
          end

        # Create sortie allocation from add values
        create_sortie_allocation(pilot_id, sortie.id, alloc, sortie.inserted_at)
      end
    end
  end

  defp create_initial_allocation(pilot_id, alloc, timestamp) do
    # baseline values represent state before this sortie = initial allocation
    repo().insert_all("pilot_allocations", [
      %{
        pilot_id: pilot_id,
        sortie_id: nil,
        allocation_type: "initial",
        sp_to_skill: alloc["baseline_skill"] || 0,
        sp_to_tokens: alloc["baseline_tokens"] || 0,
        sp_to_abilities: alloc["baseline_abilities"] || 0,
        edge_abilities_gained: alloc["baseline_edge_abilities"] || [],
        total_sp: (alloc["baseline_skill"] || 0) +
                  (alloc["baseline_tokens"] || 0) +
                  (alloc["baseline_abilities"] || 0),
        inserted_at: timestamp,
        updated_at: timestamp
      }
    ])
  end

  defp create_sortie_allocation(pilot_id, sortie_id, alloc, timestamp) do
    repo().insert_all("pilot_allocations", [
      %{
        pilot_id: pilot_id,
        sortie_id: sortie_id,
        allocation_type: "sortie",
        sp_to_skill: alloc["add_skill"] || 0,
        sp_to_tokens: alloc["add_tokens"] || 0,
        sp_to_abilities: alloc["add_abilities"] || 0,
        edge_abilities_gained: alloc["new_edge_abilities"] || [],
        total_sp: alloc["sp_to_spend"] || 0,
        inserted_at: timestamp,
        updated_at: timestamp
      }
    ])
  end

  defp create_initial_allocations_for_pilots_without_sorties do
    # Find pilots who have SP allocated but no allocation records yet
    # These are pilots who were created and allocated SP outside of sorties

    existing_pilot_ids = repo().all(
      from a in "pilot_allocations",
      select: a.pilot_id,
      distinct: true
    )

    pilots_needing_initial = repo().all(
      from p in "pilots",
      where: p.id not in ^existing_pilot_ids,
      where: p.sp_allocated_to_skill > 0 or
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

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    records = Enum.map(pilots_needing_initial, fn p ->
      %{
        pilot_id: p.id,
        sortie_id: nil,
        allocation_type: "initial",
        sp_to_skill: p.sp_to_skill || 0,
        sp_to_tokens: p.sp_to_tokens || 0,
        sp_to_abilities: p.sp_to_abilities || 0,
        edge_abilities_gained: p.edge_abilities || [],
        total_sp: (p.sp_to_skill || 0) + (p.sp_to_tokens || 0) + (p.sp_to_abilities || 0),
        inserted_at: p.inserted_at || now,
        updated_at: now
      }
    end)

    if records != [] do
      repo().insert_all("pilot_allocations", records)
    end
  end
end
```

### Phase 3: Update Application Code

#### Step 3.1: Update Sortie Schema

In `lib/aces/campaigns/sortie.ex`:

```elixir
# Remove from schema:
field :pilot_allocations, :map, default: %{}

# Add to schema:
has_many :pilot_allocations, Aces.Campaigns.PilotAllocation

# Remove from changeset cast list:
# :pilot_allocations

# Add preload where needed in queries
```

#### Step 3.2: Update Pilot Schema

In `lib/aces/companies/pilot.ex`:

```elixir
# Add to schema:
has_many :allocations, Aces.Campaigns.PilotAllocation, foreign_key: :pilot_id
```

#### Step 3.3: Update spend_sp.ex LiveView

The LiveView needs to:
1. Load existing allocations from the new table instead of JSON
2. Save allocations to the new table instead of JSON
3. Use `PilotAllocationState` for runtime state management

Key changes:
- In `mount/3`: Query `PilotAllocation` records for the sortie instead of reading `sortie.pilot_allocations`
- In `handle_event("save", ...)`: Insert/update `PilotAllocation` records instead of updating JSON

#### Step 3.4: Update SortieCompletion Module

In `lib/aces/campaigns/sortie_completion.ex`:

Update `reverse_pilot_allocations/2` and related functions to:
- Delete `PilotAllocation` records for the sortie
- Or mark them as reversed (if we want audit trail)

#### Step 3.5: Add Initial Allocation to Pilot Creation

New pilots must allocate their 150 SP before the company is "finished".

Options:
1. **Inline in company creation wizard**: After adding a pilot, show allocation UI immediately
2. **Separate step**: Company creation has a "Configure Pilots" step after adding them
3. **Pilot detail page**: Navigate to pilot page to complete allocation

Recommended: Option 1 or 2 - make it part of the company creation flow.

Create new LiveView component or modify existing pilot creation to include SP allocation.

### Phase 4: Cleanup

#### Step 4.1: Remove Old Column

After confirming everything works, create migration to remove old column:

```elixir
defmodule Aces.Repo.Migrations.RemovePilotAllocationsFromSorties do
  use Ecto.Migration

  def change do
    alter table(:sorties) do
      remove :pilot_allocations, :map, default: %{}
    end
  end
end
```

#### Step 4.2: Remove PilotAllocationState Module

Once the new system is fully working:
- Remove `lib/aces/campaigns/pilot_allocation_state.ex`
- Remove `test/aces/campaigns/pilot_allocation_state_test.exs`

Or keep it if the runtime state logic is still useful (it may be - for tracking `sp_remaining`, `has_error`, etc. during the wizard).

## Testing Strategy

### Unit Tests

1. **PilotAllocation schema tests**:
   - Changeset validations
   - Unique constraint on sortie + pilot
   - Only one initial allocation per pilot

2. **Data computation tests**:
   - `compute_pilot_totals/1` correctly sums allocations
   - Edge abilities correctly concatenated

3. **Migration tests**:
   - Existing JSON data correctly migrated
   - Initial allocations created for pilots without sorties

### Integration Tests

1. **Sortie completion flow**:
   - Complete sortie, verify allocations created
   - Verify pilot aggregated values updated

2. **Pilot creation flow**:
   - Create pilot, complete initial allocation
   - Verify initial allocation record created

3. **Reversal flow**:
   - Navigate back in wizard, verify allocations reversed

## Rollback Plan

If issues are discovered after deployment:

1. The old `pilot_allocations` column is preserved until Phase 4
2. Can revert code changes and continue using JSON column
3. Data migration is reversible (delete from `pilot_allocations` table)

## Open Questions

1. **Should we show allocation history to users?** The new table enables a "history" view showing all allocations for a pilot. Is this desired?

2. **What happens if a sortie is deleted?** Currently cascade delete. Should we preserve allocation records for audit purposes?

3. **Pilot initial allocation UI**: What's the best UX for requiring pilots to allocate their 150 SP during company creation?

## Files Changed Summary

| Action | File |
|--------|------|
| Rename | `lib/aces/campaigns/pilot_allocation.ex` → `pilot_allocation_state.ex` |
| Create | `lib/aces/campaigns/pilot_allocation.ex` (new Ecto schema) |
| Create | `priv/repo/migrations/xxx_create_pilot_allocations.exs` |
| Create | `priv/repo/migrations/xxx_migrate_pilot_allocations_data.exs` |
| Modify | `lib/aces/campaigns/sortie.ex` |
| Modify | `lib/aces/companies/pilot.ex` |
| Modify | `lib/aces_web/live/sortie_live/complete/spend_sp.ex` |
| Modify | `lib/aces/campaigns/sortie_completion.ex` |
| Create | Initial allocation UI (TBD location) |
| Later | `priv/repo/migrations/xxx_remove_pilot_allocations_from_sorties.exs` |
| Later | Remove `lib/aces/campaigns/pilot_allocation_state.ex` |

## Implementation Order

1. Phase 1.1: Rename current module (low risk, can deploy independently)
2. Phase 1.2: Create new schema and table migration
3. Phase 2.1: Create data migration
4. Phase 3.1-3.4: Update application code (deploy together)
5. Phase 3.5: Add initial allocation UI (can be separate PR)
6. Phase 4: Cleanup (after confirming stability)
