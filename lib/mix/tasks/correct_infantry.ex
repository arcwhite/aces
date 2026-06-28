defmodule Mix.Tasks.CorrectInfantry do
  @moduledoc """
  Corrects `master_units` mis-cached as `battle_armor` that are really
  conventional infantry (MUL BFType "CI"). See `specs/BFTYPE_INFANTRY_FIX.md`.

  Runs as a **dry run by default** — it fetches the MUL "Infantry" supertype
  (Type 21) for the given scopes, reports what would change, and makes no
  changes. Pass `--apply` to perform the correction.

  ## Examples

      # Dry run with the default scope (ilclan / mercenary)
      mix correct_infantry

      # Dry run against extra scopes you also seeded
      mix correct_infantry --era ilclan --faction mercenary --era dark_age --faction mercenary

      # Apply the correction
      mix correct_infantry --apply

  ## Options

      --apply            Perform the correction (default is a dry run)
      --era, -e          Era to fetch from MUL (repeatable; pairs with --faction)
      --faction, -f      Faction to fetch from MUL (repeatable; pairs with --era)

  `--era` and `--faction` are zipped positionally into scopes. With none given,
  the default scope is used. The task never deletes rows and never mutates live
  sortie state — active sorties are reported for manual review.
  """

  use Mix.Task

  alias Aces.Units.InfantryCorrection

  @shortdoc "Re-types mis-cached battle_armor units that are really conventional infantry"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [apply: :boolean, era: :keep, faction: :keep],
        aliases: [e: :era, f: :faction]
      )

    scopes = build_scopes(opts)

    if opts[:apply] do
      case InfantryCorrection.apply_correction(scopes) do
        {:ok, summary} ->
          IO.puts(InfantryCorrection.format_report(summary, :applied))

        {:error, reason} ->
          IO.puts("❌ Correction failed: #{inspect(reason)}")
          exit({:shutdown, 1})
      end
    else
      scopes
      |> InfantryCorrection.analyze()
      |> InfantryCorrection.format_report(:dry_run)
      |> IO.puts()

      IO.puts("\nRun again with --apply to perform the correction.")
    end
  end

  defp build_scopes(opts) do
    eras = for {:era, era} <- opts, do: era
    factions = for {:faction, faction} <- opts, do: faction

    case Enum.zip(eras, factions) do
      [] -> InfantryCorrection.default_scopes()
      pairs -> Enum.map(pairs, fn {era, faction} -> %{era: era, faction: faction} end)
    end
  end
end
