defmodule Aces.Repo.Migrations.AddFinalizationStepToSorties do
  use Ecto.Migration

  def change do
    alter table(:sorties) do
      add :finalization_step, :string
    end
  end
end
