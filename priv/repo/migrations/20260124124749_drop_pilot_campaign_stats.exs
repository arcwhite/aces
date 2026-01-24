defmodule Aces.Repo.Migrations.DropPilotCampaignStats do
  use Ecto.Migration

  def change do
    drop table(:pilot_campaign_stats)
  end
end
