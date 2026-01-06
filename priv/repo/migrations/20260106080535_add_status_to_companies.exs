defmodule Aces.Repo.Migrations.AddStatusToCompanies do
  use Ecto.Migration

  def change do
    alter table(:companies) do
      add :status, :string, default: "draft", null: false
    end

    create index(:companies, [:status])
  end
end
