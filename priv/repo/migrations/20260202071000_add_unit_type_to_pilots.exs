defmodule Aces.Repo.Migrations.AddUnitTypeToPilots do
  use Ecto.Migration

  def change do
    alter table(:pilots) do
      # Pilots can be qualified for: battlemech, combat_vehicle, or battle_armor
      # conventional_infantry cannot have assigned pilots
      # Default all existing pilots to "battlemech"
      add :unit_type, :string, null: false, default: "battlemech"
    end

    # Add index for filtering pilots by unit type
    create index(:pilots, [:unit_type])
  end
end
