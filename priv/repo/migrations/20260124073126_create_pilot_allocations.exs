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

    # Each pilot can only have one allocation per sortie
    create unique_index(:pilot_allocations, [:sortie_id, :pilot_id],
      where: "sortie_id IS NOT NULL",
      name: :pilot_allocations_sortie_pilot_unique
    )

    # Each pilot can only have one initial allocation
    create unique_index(:pilot_allocations, [:pilot_id],
      where: "allocation_type = 'initial'",
      name: :pilot_allocations_initial_unique
    )
  end
end
