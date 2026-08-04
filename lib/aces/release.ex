defmodule Aces.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :aces

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def seed_master_units(era, faction, type) do
    start_app()

    case Aces.MUL.TypeMapping.to_mul_ids(type) do
      [] ->
        IO.puts("Unknown type: #{type}")
        IO.puts("Valid types: battlemech, combat_vehicle, infantry, protomech")
        :error

      type_ids ->
        IO.puts("Fetching #{era} #{type} units for #{faction}...")

        filters = %{era: era, factions: [faction], types: type_ids}

        case Aces.MUL.Client.fetch_units(filters) do
          {:ok, {units, source}} ->
            total = length(units)
            IO.puts("Found #{total} units (source: #{source}). Importing...")

            {success, errors} =
              units
              |> Enum.with_index(1)
              |> Enum.reduce({0, 0}, fn {unit_data, index}, {s, e} ->
                if rem(index, 50) == 0, do: IO.puts("  #{index}/#{total}...")

                case Aces.Units.create_or_update_master_unit(unit_data) do
                  {:ok, _} -> {s + 1, e}
                  {:error, _} -> {s, e + 1}
                end
              end)

            IO.puts("Done! #{success} imported, #{errors} errors.")
            IO.puts("Total cached units: #{Aces.Units.count_cached_units()}")

          {:error, {:mul_unavailable, reason}} ->
            IO.puts("MUL unavailable: #{inspect(reason)}")

          {:error, {:query_failed, reason}} ->
            IO.puts("MUL query failed: #{inspect(reason)}")
        end
    end
  end

  @doc """
  Dry run of the BFType infantry correction (see `specs/BFTYPE_INFANTRY_FIX.md`).

  Reports what would change without modifying anything. `scopes` is a list of
  `%{era: era, faction: faction}` maps; omit to use the default scope.

      bin/aces eval 'Aces.Release.correct_infantry_dry_run()'
  """
  def correct_infantry_dry_run(scopes \\ nil) do
    start_app()

    scopes
    |> scopes_or_default()
    |> Aces.Units.InfantryCorrection.analyze()
    |> Aces.Units.InfantryCorrection.format_report(:dry_run)
    |> IO.puts()
  end

  @doc """
  Applies the BFType infantry correction (see `specs/BFTYPE_INFANTRY_FIX.md`).

  Re-types mislabeled `battle_armor` rows to `conventional_infantry` and clears
  now-invalid roster pilot assignments, in a transaction. Active sorties are
  reported for manual review, never mutated. Run the dry run first.

      bin/aces eval 'Aces.Release.correct_infantry_apply()'
  """
  def correct_infantry_apply(scopes \\ nil) do
    start_app()

    case scopes |> scopes_or_default() |> Aces.Units.InfantryCorrection.apply_correction() do
      {:ok, summary} ->
        IO.puts(Aces.Units.InfantryCorrection.format_report(summary, :applied))

      {:error, reason} ->
        IO.puts("Correction failed: #{inspect(reason)}")
    end
  end

  defp scopes_or_default(nil), do: Aces.Units.InfantryCorrection.default_scopes()
  defp scopes_or_default(scopes) when is_list(scopes), do: scopes

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end

  defp start_app do
    Application.ensure_all_started(@app)
  end
end
