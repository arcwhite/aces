defmodule Aces.Repo.Migrations.ChangeSortieMissionNumberToString do
  use Ecto.Migration

  def change do
    alter table(:sorties) do
      modify :mission_number, :string, from: :integer
    end
  end
end
