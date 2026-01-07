defmodule Aces.Repo.Migrations.CreatePilotsTable do
  use Ecto.Migration

  def change do
    create table(:pilots) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :callsign, :string
      add :description, :text
      add :portrait_url, :string
      add :skill_level, :integer, default: 4, null: false
      add :edge_tokens, :integer, default: 1, null: false
      add :edge_abilities, {:array, :string}, default: []
      add :status, :string, default: "active", null: false  # active, wounded, deceased
      add :wounds, :integer, default: 0, null: false
      add :sp_earned, :integer, default: 0, null: false
      add :mvp_awards, :integer, default: 0, null: false
      add :sorties_participated, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:pilots, [:company_id])
    create index(:pilots, [:status])
    create index(:pilots, [:skill_level])
    create unique_index(:pilots, [:company_id, :callsign], where: "callsign IS NOT NULL")
  end
end