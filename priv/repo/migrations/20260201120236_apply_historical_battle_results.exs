defmodule Aces.Repo.Migrations.ApplyHistoricalBattleResults do
  use Ecto.Migration

  @doc """
  Data migration to apply battle results from completed sorties to company rosters.

  This fixes historical data where units destroyed in battle (and not salvaged)
  weren't marked as destroyed, and pilots killed/wounded weren't updated.
  """
  def up do
    # Find all deployments from completed sorties where:
    # 1. Unit was destroyed and not salvaged -> mark company_unit as destroyed
    # 2. Pilot was killed -> mark pilot as deceased
    # 3. Pilot was wounded -> mark pilot as wounded

    # Update destroyed units (not salvaged)
    execute("""
    UPDATE company_units
    SET status = 'destroyed', updated_at = NOW()
    WHERE id IN (
      SELECT DISTINCT d.company_unit_id
      FROM deployments d
      JOIN sorties s ON d.sortie_id = s.id
      WHERE s.status = 'completed'
        AND d.damage_status = 'destroyed'
        AND d.was_salvaged = false
        AND d.company_unit_id IS NOT NULL
    )
    AND status = 'operational'
    """)

    # Update killed pilots
    execute("""
    UPDATE pilots
    SET status = 'deceased', updated_at = NOW()
    WHERE id IN (
      SELECT DISTINCT d.pilot_id
      FROM deployments d
      JOIN sorties s ON d.sortie_id = s.id
      WHERE s.status = 'completed'
        AND d.pilot_casualty = 'killed'
        AND d.pilot_id IS NOT NULL
    )
    AND status != 'deceased'
    """)

    # Update wounded pilots (only if not already deceased)
    execute("""
    UPDATE pilots
    SET status = 'wounded', updated_at = NOW()
    WHERE id IN (
      SELECT DISTINCT d.pilot_id
      FROM deployments d
      JOIN sorties s ON d.sortie_id = s.id
      WHERE s.status = 'completed'
        AND d.pilot_casualty = 'wounded'
        AND d.pilot_id IS NOT NULL
    )
    AND status = 'active'
    """)
  end

  def down do
    # This migration is not reversible as we can't know the original state
    # of units/pilots before the migration ran
    :ok
  end
end
