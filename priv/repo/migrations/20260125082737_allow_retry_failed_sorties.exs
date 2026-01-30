defmodule Aces.Repo.Migrations.AllowRetryFailedSorties do
  use Ecto.Migration

  def change do
    # Drop the existing unique constraint that prevents retrying failed sorties
    drop_if_exists unique_index(:sorties, [:campaign_id, :mission_number])

    # Create a partial unique index that only applies to non-failed sorties
    # This allows creating a new sortie with the same mission number after a failure
    create unique_index(:sorties, [:campaign_id, :mission_number],
      where: "status != 'failed'",
      name: :sorties_campaign_mission_active_unique
    )
  end
end
