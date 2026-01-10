defmodule Aces.Repo.Migrations.AddPilotAssignmentToCompanyUnits do
  use Ecto.Migration

  def change do
    alter table(:company_units) do
      add :pilot_id, references(:pilots, on_delete: :nilify_all), null: true
    end

    create unique_index(:company_units, [:pilot_id], where: "pilot_id IS NOT NULL", name: :company_units_pilot_assignment_unique)
  end
end
