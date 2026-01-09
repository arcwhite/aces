defmodule Aces.Repo.Migrations.AddPilotSpAllocationFields do
  use Ecto.Migration

  def change do
    alter table(:pilots) do
      add :sp_allocated_to_skill, :integer, default: 0, null: false
      add :sp_allocated_to_edge_tokens, :integer, default: 0, null: false  # 1 token for free
      add :sp_allocated_to_edge_abilities, :integer, default: 0, null: false
      add :sp_available, :integer, default: 150, null: false  # 150 starting SP
    end

    # Update skill_level constraints to match Alpha Strike (lower is better, 0-4 range)
    execute "ALTER TABLE pilots DROP CONSTRAINT IF EXISTS pilots_skill_level_check"
    create constraint(:pilots, :pilots_skill_level_check, check: "skill_level >= 0 AND skill_level <= 4")
  end
end
