defmodule Aces.Repo.Migrations.AddUserIdToCampaignEvents do
  use Ecto.Migration

  def change do
    alter table(:campaign_events) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:campaign_events, [:user_id])
  end
end
