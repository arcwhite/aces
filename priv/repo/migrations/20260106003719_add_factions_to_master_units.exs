defmodule Aces.Repo.Migrations.AddFactionsToMasterUnits do
  use Ecto.Migration

  def change do
    alter table(:master_units) do
      add :factions, :map
    end

    # Add GIN index for efficient faction querying
    create index(:master_units, [:factions], using: :gin)
  end
end
