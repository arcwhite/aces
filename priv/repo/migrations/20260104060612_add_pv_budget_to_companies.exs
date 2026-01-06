defmodule Aces.Repo.Migrations.AddPvBudgetToCompanies do
  use Ecto.Migration

  def change do
    alter table(:companies) do
      add :pv_budget, :integer, default: 400, null: false
    end
  end
end
