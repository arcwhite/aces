defmodule Mix.Tasks.SeedMasterUnits do
  @moduledoc """
  Seeds master units from MUL API

  This task fetches units from the Master Unit List API and caches them
  in the local database. It's designed to be respectful of the API with
  built-in rate limiting and careful filtering.

  ## Required Arguments

  Both --era and --faction are required to properly track faction availability
  per era. This allows running the task multiple times with different combinations
  to build up a complete picture of unit availability.

  ## Examples

      # Seed IlClan era mercenary BattleMechs
      mix seed_master_units --era ilclan --faction mercenary --types battlemech

      # Seed Dark Age mercenary units
      mix seed_master_units --era dark_age --faction mercenary --force

      # Seed IlClan Capellan units (adds to existing data)
      mix seed_master_units --era ilclan --faction capellan_confederation --force

      # Seed specific tonnage ranges
      mix seed_master_units --era ilclan --faction mercenary --min-tons 50 --max-tons 75

      # Dry run to see what would be fetched
      mix seed_master_units --era ilclan --faction mercenary --dry-run

  ## Valid Eras

      See `Aces.MUL.Vocabulary.era_keys/0`.

  ## Valid Factions

      mercenary, capellan_confederation, draconis_combine, federated_suns,
      free_worlds_league, lyran_commonwealth, clan_wolf, clan_jade_falcon,
      and many more (see Aces.MUL.Client.available_factions/0)
  """

  use Mix.Task
  alias Aces.{ChangesetHelpers, MUL, Units}
  alias Aces.MUL.Vocabulary

  require Logger

  @shortdoc "Seeds master units from MUL API"

  # MUL has a single "Infantry" supertype (Type 21) covering both battle armor
  # and conventional infantry. A single `--types infantry` fetch returns both
  # categories; the importer splits them by BFType into battle_armor /
  # conventional_infantry. There is no API type for one or the other, so
  # `infantry` is the only infantry keyword (it always yields both).
  @type_mappings %{
    "battlemech" => 18,
    "mech" => 18,
    "combat_vehicle" => 19,
    "vehicle" => 19,
    "infantry" => 21,
    "protomech" => 20
  }

  @valid_eras Vocabulary.era_keys()

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        era: :string,
        types: :keep,
        faction: :string,
        min_tons: :integer,
        max_tons: :integer,
        dry_run: :boolean,
        force: :boolean,
        limit: :integer
      ],
      aliases: [
        e: :era,
        t: :types,
        f: :faction,
        d: :dry_run,
        F: :force,
        l: :limit
      ]
    )

    case validate_required_opts(opts) do
      :ok ->
        result =
          if opts[:dry_run] do
            dry_run(opts)
          else
            perform_seed(opts)
          end

        if result == :error, do: System.halt(1)

      {:error, message} ->
        IO.puts("❌ #{message}")
        IO.puts("")
        IO.puts("Usage: mix seed_master_units --era <era> --faction <faction> [options]")
        IO.puts("")
        IO.puts("Required:")
        IO.puts("  --era, -e      Era name (#{Enum.join(@valid_eras, ", ")})")
        IO.puts("  --faction, -f  Faction name (e.g., mercenary, capellan_confederation)")
        IO.puts("")
        IO.puts("Options:")
        IO.puts("  --types, -t    Unit type (battlemech, combat_vehicle, etc.) - can repeat")
        IO.puts("  --min-tons     Minimum tonnage filter")
        IO.puts("  --max-tons     Maximum tonnage filter")
        IO.puts("  --force, -F    Allow seeding when units already exist")
        IO.puts("  --limit, -l    Limit number of units to import")
        IO.puts("  --dry-run, -d  Show what would be fetched without importing")
        System.halt(1)
    end
  end

  defp validate_required_opts(opts) do
    era = opts[:era]
    faction = opts[:faction]

    cond do
      is_nil(era) ->
        {:error, "Missing required argument: --era"}

      era not in @valid_eras ->
        {:error, "Invalid era '#{era}'. Valid eras: #{Enum.join(@valid_eras, ", ")}"}

      is_nil(faction) ->
        {:error, "Missing required argument: --faction"}

      true ->
        :ok
    end
  end

  defp dry_run(opts) do
    IO.puts("🔍 Dry run mode - showing what would be fetched:")
    IO.puts("")

    filters = build_filters(opts)
    display_filters(filters)

    case MUL.client().fetch_units(filters) do
      {:ok, units} ->
        IO.puts("✅ Found #{length(units)} units that would be seeded:")
        IO.puts("")

        units
        |> Enum.take(10)
        |> Enum.each(fn unit ->
          IO.puts("  • #{unit[:full_name]} (#{unit[:point_value]} PV)")
        end)

        if length(units) > 10 do
          IO.puts("  ... and #{length(units) - 10} more")
        end

        IO.puts("")
        IO.puts("Run without --dry-run to actually seed these units.")
        :ok

      {:error, reason} ->
        IO.puts("❌ Failed to fetch units: #{inspect(reason)}")
        :error
    end
  end

  @doc false
  # Public so tests can drive the seed flow against a stubbed client without
  # relying on System.halt (which run/1 handles based on the :ok | :error
  # return here).
  def perform_seed(opts) do
    existing_count = Units.count_cached_units()

    if existing_count > 0 and not (opts[:force] || false) do
      IO.puts("⚠️  Database already contains #{existing_count} cached units.")
      IO.puts("Use --force to seed additional units or clear the database first.")
      :error
    else
      IO.puts("🚀 Fetching units from Master Unit List...")
      IO.puts("")

      filters = build_filters(opts)
      display_filters(filters)

      case MUL.client().fetch_units(filters) do
        {:ok, units} ->
          total_units = length(units)
          limited_units = if opts[:limit], do: Enum.take(units, opts[:limit]), else: units

          IO.puts("✅ Found #{total_units} units from MUL API")

          if opts[:limit] do
            IO.puts("📊 Limiting to #{length(limited_units)} units due to --limit option")
          end

          IO.puts("💾 Importing to database...")
          IO.puts("")

          display_import_results(run_import(limited_units))
          :ok

        {:error, reason} ->
          IO.puts("❌ Failed to fetch units from MUL API: #{inspect(reason)}")
          IO.puts("Please check your internet connection and try again.")
          :error
      end
    end
  end

  defp build_filters(opts) do
    %{}
    |> maybe_add_era(opts[:era])
    |> maybe_add_types(opts[:types])
    |> maybe_add_faction(opts[:faction])
    |> maybe_add_tonnage(opts[:min_tons], opts[:max_tons])
  end

  defp maybe_add_era(filters, nil), do: filters
  defp maybe_add_era(filters, era), do: Map.put(filters, :era, era)

  defp maybe_add_types(filters, nil), do: filters
  defp maybe_add_types(filters, types) when is_list(types) do
    type_ids = 
      types
      |> Enum.map(&@type_mappings[&1])
      |> Enum.reject(&is_nil/1)

    if length(type_ids) > 0 do
      Map.put(filters, :types, type_ids)
    else
      filters
    end
  end
  defp maybe_add_types(filters, type) when is_binary(type) do
    maybe_add_types(filters, [type])
  end

  defp maybe_add_faction(filters, nil), do: filters
  defp maybe_add_faction(filters, faction) when is_binary(faction) do
    Map.put(filters, :factions, [faction])
  end

  defp maybe_add_tonnage(filters, nil, nil), do: filters
  defp maybe_add_tonnage(filters, min_tons, nil) when is_integer(min_tons) do
    Map.put(filters, :min_tons, min_tons)
  end
  defp maybe_add_tonnage(filters, nil, max_tons) when is_integer(max_tons) do
    Map.put(filters, :max_tons, max_tons)
  end
  defp maybe_add_tonnage(filters, min_tons, max_tons) when is_integer(min_tons) and is_integer(max_tons) do
    filters
    |> Map.put(:min_tons, min_tons)
    |> Map.put(:max_tons, max_tons)
  end

  defp display_filters(filters) do
    IO.puts("🎯 Filters:")

    Enum.each(filters, fn
      {:era, era} -> IO.puts("  • Era: #{String.capitalize(era)}")
      {:types, types} -> 
        type_names = 
          types
          |> Enum.map(fn id -> 
            @type_mappings
            |> Enum.find(fn {_, v} -> v == id end)
            |> case do
              {name, _} -> name
              nil -> "Unknown(#{id})"
            end
          end)
        IO.puts("  • Types: #{Enum.join(type_names, ", ")}")
      {:factions, factions} -> 
        IO.puts("  • Factions: #{Enum.join(factions, ", ")}")
      {:min_tons, tons} -> IO.puts("  • Min tonnage: #{tons}")
      {:max_tons, tons} -> IO.puts("  • Max tonnage: #{tons}")
      _ -> nil
    end)

    IO.puts("")
  end

  defp run_import(units) do
    start_time = System.monotonic_time()
    log_file = open_error_log()

    results = Units.import_units(units)

    Enum.each(results.errored, fn {unit_data, changeset} ->
      log_error_details(log_file, unit_data, changeset)
    end)

    close_error_log(log_file)

    elapsed = System.monotonic_time() - start_time
    elapsed_ms = System.convert_time_unit(elapsed, :native, :millisecond)

    IO.puts("✅ Import completed in #{elapsed_ms}ms")

    error_details =
      results.errored
      |> Enum.reverse()
      |> Enum.map(fn {_unit_data, changeset} -> ChangesetHelpers.format_errors(changeset) end)

    %{
      successes: results.successes,
      errors: results.errors,
      skipped: results.skipped,
      error_details: error_details
    }
  end

  defp display_import_results(%{
         successes: successes,
         errors: errors,
         skipped: skipped,
         error_details: error_details
       }) do
    IO.puts("")
    IO.puts("📊 Import Results:")
    IO.puts("  • Successfully imported: #{successes} units")

    if skipped > 0 do
      IO.puts("  • Skipped (no Alpha Strike statline): #{skipped} units")
    end

    if errors > 0 do
      IO.puts("  • Failed imports: #{errors} units")
      IO.puts("")
      IO.puts("❌ Errors encountered:")

      error_details
      |> Enum.take(5)
      |> Enum.each(fn error -> IO.puts("  • #{error}") end)

      if length(error_details) > 5 do
        IO.puts("  ... and #{length(error_details) - 5} more errors")
      end

      IO.puts("")
      IO.puts("📝 Full error details written to: #{error_log_path()}")
    end

    total_cached = Units.count_cached_units()
    IO.puts("")
    IO.puts("💾 Total cached units in database: #{total_cached}")
    IO.puts("")
    IO.puts("🎉 Master unit seeding completed!")
  end

  # Error logging helpers

  defp error_log_path do
    Path.join([File.cwd!(), "log", "seed_master_units_errors.log"])
  end

  defp open_error_log do
    path = error_log_path()
    File.mkdir_p!(Path.dirname(path))

    {:ok, file} = File.open(path, [:write, :utf8])

    IO.write(file, "# Master Unit Seed Errors - #{DateTime.utc_now()}\n")
    IO.write(file, "# ================================================\n\n")

    file
  end

  defp close_error_log(file) do
    File.close(file)
  end

  defp log_error_details(file, unit_data, changeset) do
    unit_name = unit_data[:full_name] || unit_data[:name] || "Unknown"
    mul_id = unit_data[:mul_id] || "N/A"

    IO.write(file, "## Unit: #{unit_name} (MUL ID: #{mul_id})\n\n")

    IO.write(file, "### Validation Errors:\n")
    Enum.each(changeset.errors, fn {field, {msg, opts}} ->
      IO.write(file, "  - #{field}: #{msg} (#{inspect(opts)})\n")
    end)

    IO.write(file, "\n### Raw Data:\n")
    Enum.each(unit_data, fn {key, value} ->
      IO.write(file, "  #{key}: #{inspect(value)}\n")
    end)

    IO.write(file, "\n---\n\n")
  end
end