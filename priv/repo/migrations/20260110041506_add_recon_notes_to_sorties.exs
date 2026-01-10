defmodule Aces.Repo.Migrations.AddReconNotesToSorties do
  use Ecto.Migration

  def change do
    alter table(:sorties) do
      add :recon_notes, :text
    end
  end
end
