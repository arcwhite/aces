defmodule Aces.Repo.Migrations.AddPilotAllocationsToSorties do
  use Ecto.Migration

  def change do
    alter table(:sorties) do
      add :pilot_allocations, :map, default: %{}
    end
  end
end
