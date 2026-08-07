defmodule Aces.Repo.Migrations.DropNonEraFactionKeys do
  use Ecto.Migration

  # A prior version of `Aces.MUL.Client.normalize_unit/2` merged the API's
  # flat faction list directly into the factions map, producing mixed maps
  # like %{"mercenary" => true, "ilclan" => ["mercenary"]}. The schema
  # promises era-keyed availability only; strip any top-level key that is
  # not a known era.
  @valid_eras ~w(
    ilclan
    dark_age
    late_republic
    republic
    early_republic
    jihad
    civil_war
    clan_invasion
    late_succession_war
    early_succession_war
    star_league
  )

  def up do
    era_keys_sql =
      @valid_eras
      |> Enum.map(&"'#{&1}'")
      |> Enum.join(", ")

    execute("""
    UPDATE master_units
    SET factions = COALESCE(
      (
        SELECT jsonb_object_agg(key, value)
        FROM jsonb_each(factions)
        WHERE key IN (#{era_keys_sql})
      ),
      '{}'::jsonb
    )
    WHERE factions IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM jsonb_each(factions)
        WHERE key NOT IN (#{era_keys_sql})
      );
    """)
  end

  def down do
    :ok
  end
end
