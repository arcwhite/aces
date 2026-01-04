defmodule Aces.Repo.Migrations.CreateCompaniesTables do
  use Ecto.Migration

  def change do
    # Companies table
    create table(:companies) do
      add :name, :string, null: false
      add :description, :text
      add :warchest_balance, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:companies, [:name])
    create index(:companies, [:updated_at])

    # Company memberships (join table for users and companies)
    create table(:company_memberships) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "viewer"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:company_memberships, [:user_id, :company_id])
    create index(:company_memberships, [:user_id])
    create index(:company_memberships, [:company_id])
    create index(:company_memberships, [:role])

    # Master units table (placeholder for future MUL integration)
    create table(:master_units) do
      add :mul_id, :integer, null: false
      add :name, :string, null: false
      add :variant, :string
      add :full_name, :string
      add :unit_type, :string, null: false
      add :tonnage, :integer
      add :point_value, :integer
      add :battle_value, :integer
      add :technology_base, :string
      add :rules_level, :string
      add :role, :string
      add :cost, :integer
      add :date_introduced, :integer
      add :era_id, :integer

      # Alpha Strike fields
      add :bf_move, :string
      add :bf_armor, :integer
      add :bf_structure, :integer
      add :bf_damage_short, :string
      add :bf_damage_medium, :string
      add :bf_damage_long, :string
      add :bf_overheat, :integer
      add :bf_abilities, :string

      add :image_url, :string
      add :is_published, :boolean, default: false
      add :last_synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:master_units, [:mul_id])
    create index(:master_units, [:name])
    create index(:master_units, [:unit_type])
    create index(:master_units, [:point_value])

    # Company units table
    create table(:company_units) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :master_unit_id, references(:master_units, on_delete: :restrict), null: false
      add :custom_name, :string
      add :status, :string, default: "operational", null: false
      add :purchase_cost_sp, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:company_units, [:company_id])
    create index(:company_units, [:master_unit_id])
    create index(:company_units, [:status])
  end
end
