defmodule Aces.Repo.Migrations.CreateCampaignsAndSortiesTables do
  use Ecto.Migration

  def change do
    # Campaigns table
    create table(:campaigns) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text
      add :status, :string, default: "active", null: false  # active, completed, failed
      add :difficulty_level, :string, default: "standard", null: false  # rookie, standard, veteran, elite
      add :pv_limit_modifier, :float, default: 1.0, null: false  # multiplier for sortie PV limits
      add :reward_modifier, :float, default: 1.0, null: false  # multiplier for sortie rewards
      add :experience_modifier, :float, default: 1.0, null: false  # modifier based on pilot SP totals
      add :warchest_balance, :integer, default: 0, null: false
      add :keywords, {:array, :string}, default: []  # campaign keywords gained during sorties
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:campaigns, [:company_id])
    create index(:campaigns, [:status])
    create index(:campaigns, [:started_at])

    # Only one active campaign per company
    create unique_index(:campaigns, [:company_id], where: "status = 'active'", name: :campaigns_company_active_unique)

    # Sorties table
    create table(:sorties) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :mission_number, :integer, null: false  # sortie sequence within campaign
      add :name, :string, null: false
      add :description, :text
      add :pv_limit, :integer, null: false
      add :status, :string, default: "setup", null: false  # setup, in_progress, success, failed, completed
      add :force_commander_id, references(:pilots, on_delete: :nilify_all), null: true

      # Recon options (costs applied at end of sortie)
      add :recon_options, {:array, :map}, default: []  # [%{name: "Aerial Recon", cost_sp: 50}]
      add :recon_total_cost, :integer, default: 0, null: false

      # Post-battle results
      add :was_successful, :boolean
      add :primary_objective_income, :integer, default: 0
      add :secondary_objectives_income, :integer, default: 0
      add :waypoints_income, :integer, default: 0
      add :rearming_cost, :integer, default: 0
      add :total_income, :integer, default: 0
      add :total_expenses, :integer, default: 0
      add :net_earnings, :integer, default: 0
      add :mvp_pilot_id, references(:pilots, on_delete: :nilify_all), null: true
      add :sp_per_participating_pilot, :integer, default: 0
      add :keywords_gained, {:array, :string}, default: []

      # Metadata
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:sorties, [:campaign_id])
    create index(:sorties, [:status])
    create index(:sorties, [:mission_number])
    create unique_index(:sorties, [:campaign_id, :mission_number])

    # Deployments table (unit/pilot assignment to sorties)
    create table(:deployments) do
      add :sortie_id, references(:sorties, on_delete: :delete_all), null: false
      add :company_unit_id, references(:company_units, on_delete: :delete_all), null: false
      add :pilot_id, references(:pilots, on_delete: :nilify_all), null: true  # can deploy with no pilot

      # Pre-sortie configuration
      add :configuration_changes, :text  # omnimech variant changes, etc.
      add :configuration_cost_sp, :integer, default: 0

      # Post-battle status
      add :damage_status, :string  # operational, armor_damaged, structure_damaged, crippled, salvageable, destroyed
      add :pilot_casualty, :string  # none, wounded, killed
      add :was_salvaged, :boolean, default: false
      add :repair_cost_sp, :integer, default: 0
      add :casualty_cost_sp, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:deployments, [:sortie_id])
    create index(:deployments, [:company_unit_id])
    create index(:deployments, [:pilot_id])
    create unique_index(:deployments, [:sortie_id, :company_unit_id])

    # Campaign events table (timeline tracking)
    create table(:campaign_events) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :event_type, :string, null: false  # sortie_started, sortie_completed, pilot_hired, unit_purchased, etc.
      add :event_data, :map, default: %{}  # JSON data specific to event type
      add :description, :text, null: false
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:campaign_events, [:campaign_id])
    create index(:campaign_events, [:event_type])
    create index(:campaign_events, [:occurred_at])

    # Pilot campaign stats table (tracks per-campaign pilot performance)
    create table(:pilot_campaign_stats) do
      add :pilot_id, references(:pilots, on_delete: :delete_all), null: false
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :sorties_participated, :integer, default: 0, null: false
      add :sp_earned, :integer, default: 0, null: false
      add :mvp_awards, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:pilot_campaign_stats, [:pilot_id])
    create index(:pilot_campaign_stats, [:campaign_id])
    create unique_index(:pilot_campaign_stats, [:pilot_id, :campaign_id])
  end
end