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

  def seed_master_units(era, faction) do
    start_app()

    IO.puts("Fetching #{era} units for #{faction}...")

    filters = %{era: era, factions: [faction]}

    case Aces.MUL.Client.fetch_units(filters) do
      {:ok, units} ->
        total = length(units)
        IO.puts("Found #{total} units. Importing...")

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

      {:error, reason} ->
        IO.puts("Failed to fetch units: #{reason}")
    end
  end

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
