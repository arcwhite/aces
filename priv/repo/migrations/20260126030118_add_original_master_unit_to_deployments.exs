defmodule Aces.Repo.Migrations.AddOriginalMasterUnitToDeployments do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      # Track the original master_unit_id when deployment was created
      # This allows calculating configuration costs based on original vs final variant
      add :original_master_unit_id, references(:master_units, on_delete: :nothing)
    end

    # Backfill existing deployments: set original_master_unit_id from company_unit's current master_unit_id
    execute """
      UPDATE deployments
      SET original_master_unit_id = company_units.master_unit_id
      FROM company_units
      WHERE deployments.company_unit_id = company_units.id
      AND deployments.original_master_unit_id IS NULL
    """, ""
  end
end
