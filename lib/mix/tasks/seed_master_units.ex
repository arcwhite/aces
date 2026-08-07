defmodule Mix.Tasks.SeedMasterUnits do
  @moduledoc """
  Seeds master units from MUL API

  This task fetches units from the Master Unit List API and caches them
  in the local database. It's designed to be respectful of the API with
  built-in rate limiting and careful filtering.

  ## Required Arguments (single-combination mode)

  Both --era and --faction are required to properly track faction availability
  per era. This allows running the task multiple times with different combinations
  to build up a complete picture of unit availability.

  ## Examples — single combination

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

  ## Matrix mode

  `--matrix` iterates every era × faction combination the unit-search modal
  exposes (5 eras × 12 factions = 60 QuickList requests). Faction availability
  is only recorded for combinations we explicitly seed, so a full matrix run is
  the way to make the cache actually usable for filtered searches.

      # Full matrix — ~2–4 minutes wall clock at 1s/request
      mix seed_master_units --matrix

      # Re-seed a single era (12 requests) after a MUL data change
      mix seed_master_units --matrix --era ilclan

      # Re-seed a single faction across all eras (5 requests)
      mix seed_master_units --matrix --faction clan_wolf

      # Print the combination list without calling the API
      mix seed_master_units --matrix --dry-run

  Matrix mode requests the modal's supported unit types explicitly
  (`Types=18&Types=19&Types=20&Types=21` — BattleMech, Combat Vehicle,
  ProtoMech, Infantry). Use `--matrix --all-types` to survey what else MUL
  holds — aerospace, large craft, and support vehicles all normalise to
  `unit_type: "other"` and can't be selected in the modal, so the default
  keeps them out of the cache.

  Matrix mode bypasses the "already contains cached units" guard — the whole
  point is to accumulate. Runs are idempotent: `create_or_update_master_unit/1`
  merges faction data per era, so repeated runs top up availability rather
  than duplicating rows.

  ## Valid Eras

      ilclan, dark_age, republic, jihad, civil_war, clan_invasion

  ## Valid Factions

      mercenary, capellan_confederation, draconis_combine, federated_suns,
      free_worlds_league, lyran_commonwealth, clan_wolf, clan_jade_falcon,
      and many more (see Aces.MUL.Client.available_factions/0)
  """

  use Mix.Task
  alias Aces.{ChangesetHelpers, Repo, Units}
  alias Aces.MUL.{Client, TypeMapping}
  alias Aces.Units.MasterUnit

  import Ecto.Query, only: [from: 2]

  require Logger

  @shortdoc "Seeds master units from MUL API"

  # Internal type keywords accepted by --types. The MUL-id lookup is delegated
  # to Aces.MUL.TypeMapping so the mapping stays in one place.
  @accepted_type_keywords ~w(battlemech mech combat_vehicle vehicle infantry protomech)

  @valid_eras ~w(ilclan dark_age late_republic early_republic jihad civil_war clan_invasion)

  # Eras exposed by the unit-search modal's era selector. Matrix mode iterates
  # this list; other @valid_eras are only reachable via single-combination runs.
  @matrix_eras ~w(ilclan dark_age late_republic early_republic clan_invasion)

  # Factions exposed by the unit-search modal's <select>. Keep in sync with
  # `lib/aces_web/live/components/unit_search_modal.ex`. Matrix mode iterates
  # every combination of @matrix_eras × @matrix_factions.
  @matrix_factions ~w(
    mercenary
    capellan_confederation
    draconis_combine
    federated_suns
    free_worlds_league
    lyran_commonwealth
    republic_of_the_sphere
    clan_wolf
    clan_jade_falcon
    clan_ghost_bear
    clan_sea_fox
    clan_hell_horses
  )

  # Unit-type IDs the modal can filter on: BattleMech, Combat Vehicle,
  # ProtoMech, Infantry. Type 21 (Infantry) returns both battle armor and
  # conventional infantry in one call; the importer splits them by BFType.
  # Sourced from TypeMapping so the modal-supported set stays in one place.
  @matrix_supported_type_ids TypeMapping.supported_mul_type_ids()

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
        limit: :integer,
        matrix: :boolean,
        all_types: :boolean
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

    if opts[:matrix] do
      run_matrix(opts)
    else
      run_single(opts)
    end
  end

  defp run_single(opts) do
    case validate_required_opts(opts) do
      :ok ->
        if opts[:dry_run] do
          dry_run(opts)
        else
          perform_seed(opts)
        end

      {:error, message} ->
        IO.puts("❌ #{message}")
        IO.puts("")
        IO.puts("Usage: mix seed_master_units --era <era> --faction <faction> [options]")
        IO.puts("       mix seed_master_units --matrix [--era X] [--faction Y] [--all-types]")
        IO.puts("")
        IO.puts("Required (single-combination mode):")
        IO.puts("  --era, -e      Era name (#{Enum.join(@valid_eras, ", ")})")
        IO.puts("  --faction, -f  Faction name (e.g., mercenary, capellan_confederation)")
        IO.puts("")
        IO.puts("Options:")
        IO.puts("  --types, -t    Unit type (#{Enum.join(@accepted_type_keywords, ", ")}) - can repeat")
        IO.puts("  --min-tons     Minimum tonnage filter")
        IO.puts("  --max-tons     Maximum tonnage filter")
        IO.puts("  --force, -F    Allow seeding when units already exist")
        IO.puts("  --limit, -l    Limit number of units to import")
        IO.puts("  --dry-run, -d  Show what would be fetched without importing")
        IO.puts("  --matrix       Iterate every era × faction combination the UI exposes")
        IO.puts("  --all-types    In matrix mode, omit the type filter (survey mode)")
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

    case Client.fetch_units(filters) do
      {:ok, {units, source}} ->
        IO.puts("✅ Found #{length(units)} units (source: #{source}) that would be seeded:")
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

      {:error, {kind, reason}} ->
        IO.puts("❌ Failed to fetch units (#{kind}): #{inspect(reason)}")
    end
  end

  defp perform_seed(opts) do
    existing_count = Units.count_cached_units()

    if existing_count > 0 and not (opts[:force] || false) do
      IO.puts("⚠️  Database already contains #{existing_count} cached units.")
      IO.puts("Use --force to seed additional units or clear the database first.")
      System.halt(1)
    end

    IO.puts("🚀 Fetching units from Master Unit List...")
    IO.puts("")

    filters = build_filters(opts)
    display_filters(filters)

    case Client.fetch_units(filters) do
      {:ok, {units, source}} ->
        total_units = length(units)
        limited_units = if opts[:limit], do: Enum.take(units, opts[:limit]), else: units

        IO.puts("✅ Found #{total_units} units (source: #{source})")

        if opts[:limit] do
          IO.puts("📊 Limiting to #{length(limited_units)} units due to --limit option")
        end

        IO.puts("💾 Importing to database...")
        IO.puts("")

        import_results = import_units(limited_units)

        display_import_results(import_results)

      {:error, {:mul_unavailable, reason}} ->
        IO.puts("❌ MUL service unavailable: #{inspect(reason)}")
        IO.puts("Please check your network / retry later — this is not a query error.")
        System.halt(1)

      {:error, {:query_failed, reason}} ->
        IO.puts("❌ MUL rejected the query: #{inspect(reason)}")
        IO.puts("Check the era/faction/type combination is valid on the MUL.")
        System.halt(1)
    end
  end

  # Matrix mode

  defp run_matrix(opts) do
    case validate_matrix_opts(opts) do
      :ok ->
        combos = matrix_combinations(opts)

        if opts[:dry_run] do
          matrix_dry_run(combos, opts)
        else
          matrix_seed(combos, opts)
        end

      {:error, message} ->
        IO.puts("❌ #{message}")
        System.halt(1)
    end
  end

  defp validate_matrix_opts(opts) do
    era = opts[:era]
    faction = opts[:faction]

    cond do
      era != nil and era not in @matrix_eras ->
        {:error,
         "Invalid --era for --matrix: '#{era}'. Valid: #{Enum.join(@matrix_eras, ", ")}"}

      faction != nil and faction not in @matrix_factions ->
        {:error,
         "Invalid --faction for --matrix: '#{faction}'. Valid: #{Enum.join(@matrix_factions, ", ")}"}

      true ->
        :ok
    end
  end

  defp matrix_combinations(opts) do
    eras = if opts[:era], do: [opts[:era]], else: @matrix_eras
    factions = if opts[:faction], do: [opts[:faction]], else: @matrix_factions

    for era <- eras, faction <- factions, do: {era, faction}
  end

  defp matrix_type_ids(opts) do
    if opts[:all_types], do: nil, else: @matrix_supported_type_ids
  end

  defp matrix_dry_run(combos, opts) do
    types = matrix_type_ids(opts)

    IO.puts("🔍 Matrix dry run — no API calls will be made.")
    IO.puts("")
    IO.puts("Combinations (#{length(combos)}):")

    Enum.each(combos, fn {era, faction} ->
      IO.puts("  • #{era} / #{faction}")
    end)

    IO.puts("")
    IO.puts("Type filter: #{matrix_type_filter_label(types)}")
    IO.puts("Total QuickList requests: #{length(combos)}")
    IO.puts("Rate limit: 1s between requests → ~#{length(combos)}s minimum wall clock")
  end

  defp matrix_type_filter_label(nil), do: "(none — --all-types)"

  defp matrix_type_filter_label(types) do
    "Types=" <> Enum.join(types, "&Types=")
  end

  defp matrix_seed(combos, opts) do
    before_count = Units.count_cached_units()
    types = matrix_type_ids(opts)

    IO.puts("🚀 Matrix seed — #{length(combos)} combinations (era × faction)")
    IO.puts("   Type filter: #{matrix_type_filter_label(types)}")
    IO.puts("💾 Starting cache count: #{before_count}")
    IO.puts("")

    {results, failures} =
      combos
      |> Enum.reduce({[], []}, fn combo, {results, failures} ->
        case seed_combination(combo, types) do
          {:ok, stats} ->
            display_combination_line(stats)
            {[stats | results], failures}

          {:error, reason} ->
            IO.puts("  ❌ #{combo_label(combo)} → #{inspect(reason)}")
            {results, [{combo, reason} | failures]}
        end
      end)

    after_count = Units.count_cached_units()

    IO.puts("")
    IO.puts("💾 Ending cache count: #{after_count} (+#{after_count - before_count})")

    display_bf_type_histogram()
    display_matrix_summary(Enum.reverse(results), Enum.reverse(failures))

    # Per-combination failures are non-halting by design: the histogram is the
    # deliverable, and one flaky MUL request out of 60 shouldn't fail the run
    # or block bin/local-smoke's start_server step. Failures are surfaced in
    # the summary above.
    :ok
  end

  defp seed_combination({era, faction}, types) do
    filters = build_matrix_filters(era, faction, types)
    before_count = Units.count_cached_units()

    case Client.fetch_units(filters) do
      {:ok, {units, _source}} ->
        {successes, errors} =
          Enum.reduce(units, {0, 0}, fn unit_data, {s, e} ->
            case Units.create_or_update_master_unit(unit_data) do
              {:ok, _} -> {s + 1, e}
              {:error, _} -> {s, e + 1}
            end
          end)

        after_count = Units.count_cached_units()
        new_count = after_count - before_count
        merged_count = successes - new_count

        {:ok,
         %{
           era: era,
           faction: faction,
           fetched: length(units),
           successes: successes,
           errors: errors,
           new: new_count,
           merged: merged_count
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_matrix_filters(era, faction, nil) do
    %{era: era, factions: [faction]}
  end

  defp build_matrix_filters(era, faction, types) when is_list(types) do
    %{era: era, factions: [faction], types: types}
  end

  defp combo_label({era, faction}), do: "#{era} / #{faction}"

  defp display_combination_line(stats) do
    parts = ["#{stats.new} new", "#{stats.merged} merged"]

    parts =
      if stats.errors > 0 do
        parts ++ ["#{stats.errors} errored"]
      else
        parts
      end

    IO.puts(
      "#{stats.era} / #{stats.faction} → #{stats.fetched} units (#{Enum.join(parts, ", ")})"
    )
  end

  defp display_bf_type_histogram do
    histogram = bf_type_histogram()
    known = MapSet.new(TypeMapping.known_bf_types())

    {expected, unexpected} =
      Enum.split_with(histogram, fn {bf_type, _count} ->
        bf_type != "unknown" and MapSet.member?(known, String.upcase(bf_type))
      end)

    formatted =
      histogram
      |> Enum.sort_by(fn {_type, count} -> -count end)
      |> Enum.map_join(" · ", fn {type, count} -> "#{type} #{count}" end)

    IO.puts("")
    IO.puts("📊 bf_type histogram (all cached units):")
    IO.puts("  #{formatted}")

    if unexpected != [] do
      IO.puts("")
      IO.puts("⚠️  Unexpected BFType values (not in TypeMapping.known_bf_types/0):")

      unexpected
      |> Enum.sort_by(fn {_type, count} -> -count end)
      |> Enum.each(fn {type, count} ->
        IO.puts("  • #{type} → #{count} units")
      end)

      IO.puts("")
      IO.puts("  Expected set: #{Enum.join(Enum.sort(TypeMapping.known_bf_types()), ", ")}")
    else
      expected_names = expected |> Enum.map(fn {t, _} -> String.upcase(t) end) |> Enum.sort()
      IO.puts("  (all values within expected set: #{Enum.join(expected_names, ", ")})")
    end
  end

  defp bf_type_histogram do
    from(u in MasterUnit,
      select: {u.bf_type, count(u.id)},
      group_by: u.bf_type
    )
    |> Repo.all()
    |> Enum.map(fn {bf_type, count} -> {bf_type || "unknown", count} end)
  end

  defp display_matrix_summary(results, failures) do
    zero_result_combos = Enum.filter(results, fn r -> r.fetched == 0 end)

    IO.puts("")
    IO.puts("📋 Matrix summary:")
    IO.puts("  • Combinations run: #{length(results) + length(failures)}")
    IO.puts("  • Succeeded: #{length(results)}")
    IO.puts("  • Failed: #{length(failures)}")
    IO.puts("  • Zero-result combinations: #{length(zero_result_combos)}")

    if zero_result_combos != [] do
      IO.puts("")
      IO.puts("⚠️  Combinations returning zero units:")

      Enum.each(zero_result_combos, fn r ->
        IO.puts("  • #{r.era} / #{r.faction}")
      end)
    end

    if failures != [] do
      IO.puts("")
      IO.puts("❌ Combinations that errored:")

      Enum.each(failures, fn {combo, reason} ->
        IO.puts("  • #{combo_label(combo)} → #{inspect(reason)}")
      end)
    end
  end

  # Single-combination helpers

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
      |> Enum.flat_map(&TypeMapping.to_mul_ids/1)
      |> Enum.uniq()

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

  # Human-readable label for a MUL Types id. Only used for the display
  # summary; the canonical mapping lives in TypeMapping.
  defp mul_type_id_label(18), do: "battlemech"
  defp mul_type_id_label(19), do: "combat_vehicle"
  defp mul_type_id_label(20), do: "protomech"
  defp mul_type_id_label(21), do: "infantry"
  defp mul_type_id_label(id), do: "Unknown(#{id})"

  defp display_filters(filters) do
    IO.puts("🎯 Filters:")

    Enum.each(filters, fn
      {:era, era} -> IO.puts("  • Era: #{String.capitalize(era)}")
      {:types, types} ->
        type_names = Enum.map(types, &mul_type_id_label/1)
        IO.puts("  • Types: #{Enum.join(type_names, ", ")}")
      {:factions, factions} ->
        IO.puts("  • Factions: #{Enum.join(factions, ", ")}")
      {:min_tons, tons} -> IO.puts("  • Min tonnage: #{tons}")
      {:max_tons, tons} -> IO.puts("  • Max tonnage: #{tons}")
      _ -> nil
    end)

    IO.puts("")
  end

  defp import_units(units) do
    start_time = System.monotonic_time()
    log_file = open_error_log()

    results = %{success: 0, errors: 0, error_details: [], log_file: log_file}

    final_results =
      units
      |> Enum.with_index(1)
      |> Enum.reduce(results, fn {unit_data, index}, acc ->
        if rem(index, 10) == 0 do
          IO.write("\r💾 Imported #{index}/#{length(units)} units")
        end

        case Units.create_or_update_master_unit(unit_data) do
          {:ok, _unit} ->
            %{acc | success: acc.success + 1}

          {:error, changeset} ->
            error_msg = ChangesetHelpers.format_errors(changeset)
            log_error_details(acc.log_file, unit_data, changeset)
            %{
              acc |
              errors: acc.errors + 1,
              error_details: [error_msg | acc.error_details]
            }
        end
      end)

    close_error_log(log_file)

    elapsed = System.monotonic_time() - start_time
    elapsed_ms = System.convert_time_unit(elapsed, :native, :millisecond)

    IO.write("\r")  # Clear progress line
    IO.puts("✅ Import completed in #{elapsed_ms}ms")

    Map.delete(final_results, :log_file)
  end

  defp display_import_results(%{success: success, errors: errors, error_details: error_details}) do
    IO.puts("")
    IO.puts("📊 Import Results:")
    IO.puts("  • Successfully imported: #{success} units")

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
