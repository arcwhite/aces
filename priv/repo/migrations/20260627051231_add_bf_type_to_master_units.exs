defmodule Aces.Repo.Migrations.AddBfTypeToMasterUnits do
  use Ecto.Migration

  def change do
    alter table(:master_units) do
      # MUL sub-type discriminator ("BA" vs "CI") for the shared "Infantry"
      # supertype. Nullable: non-infantry units have no BFType, and rows cached
      # before this column existed are backfilled on the next MUL sync.
      add :bf_type, :string
    end
  end
end
