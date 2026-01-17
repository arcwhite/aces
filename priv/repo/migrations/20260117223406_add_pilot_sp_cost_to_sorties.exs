defmodule Aces.Repo.Migrations.AddPilotSpCostToSorties do
  use Ecto.Migration

  def change do
    alter table(:sorties) do
      add :pilot_sp_cost, :integer, default: 0
    end
  end
end
