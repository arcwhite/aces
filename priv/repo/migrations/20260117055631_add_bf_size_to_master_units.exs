defmodule Aces.Repo.Migrations.AddBfSizeToMasterUnits do
  use Ecto.Migration

  def change do
    alter table(:master_units) do
      add :bf_size, :integer
    end
  end
end
