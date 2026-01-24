defmodule Aces.Repo.Migrations.RemovePilotAllocationsJsonFromSorties do
  @moduledoc """
  Removes the deprecated pilot_allocations JSON column from sorties.

  This column has been replaced by the pilot_allocations table (created in
  20260124073126_create_pilot_allocations.exs) and all data has been migrated
  (in 20260124073742_migrate_pilot_allocations_data.exs).

  This is Phase 4 cleanup of the pilot allocations migration.
  """
  use Ecto.Migration

  def change do
    alter table(:sorties) do
      remove :pilot_allocations, :map, default: %{}
    end
  end
end
