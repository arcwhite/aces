defmodule Aces.Units.InfantryCorrection do
  @moduledoc """
  One-off corrective tooling for the BFType mis-classification bug
  (see `specs/BFTYPE_INFANTRY_FIX.md`).

  Older MUL syncs cached every "Infantry" supertype unit (MUL Type 21) as
  `battle_armor`, because the importer ignored the `BFType` sub-type field. As a
  result ~40% of cached `battle_armor` rows are really conventional infantry
  (`BFType "CI"`). This module re-fetches the Type-21 list from the MUL for the
  era/faction scopes the environment was seeded with, recovers each unit's true
  `BFType`, and:

    * re-types mislabeled `master_units` rows to `conventional_infantry`, and
    * clears now-invalid roster `pilot_id` assignments on `company_units`.

  Safety properties:

    * **Never deletes** `master_units` (rows may be referenced by company units);
      it only re-types them.
    * **Never mutates live sortie state.** Deployments and pilot allocations on
      active sorties are *reported* for manual review, not changed.
    * `analyze/1` changes nothing; `apply_correction/1` does the work in a
      single transaction.

  Coverage depends on the scopes passed: a cached `battle_armor` row whose
  `mul_id` is absent from the fetched Type-21 set cannot be verified and is left
  untouched (reported under `:uncovered`). Widen the scopes if that list is
  non-empty for units you care about.
  """

  import Ecto.Query
  require Logger

  alias Aces.Campaigns.{Deployment, Sortie}
  alias Aces.Companies.CompanyUnit
  alias Aces.MUL.Client
  alias Aces.Repo
  alias Aces.Units.MasterUnit

  @infantry_type_id 21
  @active_sortie_statuses ~w(setup in_progress finalizing)

  # The environments here were seeded primarily from this scope. Override via the
  # `scopes` argument (a list of `%{era: era, faction: faction}`) if you seeded
  # additional era/faction combinations.
  @default_scopes [%{era: "ilclan", faction: "mercenary"}]

  @doc """
  Returns the default era/faction scopes used when none are supplied.
  """
  def default_scopes, do: @default_scopes

  @doc """
  Analyses what a correction would do, without changing anything.

  Returns a report map with the rows that would flip, cached `battle_armor` rows
  that could not be verified against the MUL, the affected/piloted company units,
  and any deployments on active sorties that touch the affected units.
  """
  def analyze(scopes \\ @default_scopes) do
    bf_type_map = build_bf_type_map(scopes)

    cached_battle_armor =
      Repo.all(from(m in MasterUnit, where: m.unit_type == "battle_armor"))

    {covered, uncovered} =
      Enum.split_with(cached_battle_armor, &Map.has_key?(bf_type_map, &1.mul_id))

    to_flip =
      Enum.filter(covered, fn unit ->
        Map.get(bf_type_map, unit.mul_id) == "conventional_infantry"
      end)

    flip_ids = Enum.map(to_flip, & &1.id)

    affected_company_units =
      Repo.all(
        from(cu in CompanyUnit,
          where: cu.master_unit_id in ^flip_ids,
          preload: [:pilot, :master_unit, :company]
        )
      )

    %{
      scopes: scopes,
      mul_units_fetched: map_size(bf_type_map),
      cached_battle_armor: length(cached_battle_armor),
      to_flip: to_flip,
      uncovered: uncovered,
      affected_company_units: affected_company_units,
      piloted_company_units: Enum.filter(affected_company_units, & &1.pilot_id),
      active_sortie_deployments: active_sortie_deployments(flip_ids)
    }
  end

  @doc """
  Applies the correction inside a transaction and returns `{:ok, summary}`.

  Re-types mislabeled `master_units` to `conventional_infantry` (setting
  `bf_type` to `"CI"`) and clears roster `pilot_id` on any `company_units` now
  pointing at them. Active-sortie deployments are reported but left untouched.
  """
  def apply_correction(scopes \\ @default_scopes) do
    report = analyze(scopes)
    flip_ids = Enum.map(report.to_flip, & &1.id)
    cleared_units = report.piloted_company_units

    Repo.transaction(fn ->
      {flipped_count, _} =
        Repo.update_all(
          from(m in MasterUnit, where: m.id in ^flip_ids),
          set: [unit_type: "conventional_infantry", bf_type: "CI", updated_at: now()]
        )

      {cleared_pilot_count, _} =
        Repo.update_all(
          from(cu in CompanyUnit,
            where: cu.master_unit_id in ^flip_ids and not is_nil(cu.pilot_id)
          ),
          set: [pilot_id: nil, updated_at: now()]
        )

      Map.merge(report, %{
        flipped_count: flipped_count,
        cleared_pilot_count: cleared_pilot_count,
        cleared_units: cleared_units
      })
    end)
  end

  @doc """
  Renders a human-readable summary of an `analyze/1` or `apply_correction/1`
  report. `mode` is `:dry_run` (default) or `:applied`.
  """
  def format_report(report, mode \\ :dry_run) do
    header =
      case mode do
        :applied -> "BFType infantry correction — APPLIED"
        :dry_run -> "BFType infantry correction — DRY RUN (no changes made)"
      end

    scopes = Enum.map_join(report.scopes, ", ", fn %{era: e, faction: f} -> "#{e}/#{f}" end)

    base = [
      header,
      String.duplicate("=", String.length(header)),
      "Scopes fetched from MUL: #{scopes}",
      "MUL Type-21 units fetched: #{report.mul_units_fetched}",
      "Cached battle_armor rows:  #{report.cached_battle_armor}",
      "  → would re-type to conventional_infantry: #{length(report.to_flip)}",
      "  → not present in fetched MUL set (left as-is): #{length(report.uncovered)}",
      "Affected company units: #{length(report.affected_company_units)} " <>
        "(#{length(report.piloted_company_units)} currently have a pilot)",
      "Active-sortie deployments touching affected units: " <>
        "#{length(report.active_sortie_deployments)}"
    ]

    base
    |> Kernel.++(flip_lines(report.to_flip))
    |> Kernel.++(pilot_lines(mode, report))
    |> Kernel.++(active_sortie_lines(report.active_sortie_deployments))
    |> Kernel.++(uncovered_lines(report.uncovered))
    |> Enum.join("\n")
  end

  defp flip_lines([]), do: []

  defp flip_lines(units) do
    ["", "Units to re-type:"] ++
      Enum.map(units, fn u -> "  • #{u.full_name || u.name} (mul_id #{u.mul_id})" end)
  end

  defp pilot_lines(_mode, %{piloted_company_units: []}), do: []

  defp pilot_lines(mode, %{piloted_company_units: units}) do
    verb = if mode == :applied, do: "Cleared pilot from", else: "Would clear pilot from"

    ["", "#{verb} these company units (pilots become unassigned, not deleted):"] ++
      Enum.map(units, fn cu ->
        "  • company ##{cu.company_id} · #{cu.master_unit.full_name || cu.master_unit.name}" <>
          " · pilot ##{cu.pilot_id}"
      end)
  end

  defp active_sortie_lines([]), do: []

  defp active_sortie_lines(deployments) do
    ["", "⚠️  Active sorties referencing affected units — REVIEW MANUALLY (not changed):"] ++
      Enum.map(deployments, fn d ->
        pilot = if d.pilot_id, do: "pilot ##{d.pilot_id}", else: "no pilot"

        "  • sortie ##{d.sortie_id} (#{d.sortie.status}) · " <>
          "#{d.company_unit.master_unit.full_name || d.company_unit.master_unit.name} · #{pilot}"
      end)
  end

  defp uncovered_lines([]), do: []

  defp uncovered_lines(units) do
    [
      "",
      "Cached battle_armor not found in the fetched MUL set (#{length(units)}) — " <>
        "widen scopes to verify these:"
    ] ++ Enum.map(units, fn u -> "  • #{u.full_name || u.name} (mul_id #{u.mul_id})" end)
  end

  # Builds a `mul_id => corrected unit_type` map from fresh MUL Type-21 fetches.
  # The client normalizes each unit's BFType into our unit_type, so the values
  # are "conventional_infantry" or "battle_armor".
  defp build_bf_type_map(scopes) do
    Enum.reduce(scopes, %{}, fn %{era: era, faction: faction}, acc ->
      merge_scope_bf_types(acc, era, faction)
    end)
  end

  defp merge_scope_bf_types(acc, era, faction) do
    case Client.fetch_units(%{era: era, factions: [faction], types: [@infantry_type_id]}) do
      {:ok, units} ->
        Enum.reduce(units, acc, &put_bf_type/2)

      {:error, reason} ->
        Logger.warning("MUL Type-21 fetch failed for #{era}/#{faction}: #{inspect(reason)}")
        acc
    end
  end

  defp put_bf_type(%{mul_id: mul_id, unit_type: unit_type}, map) when is_integer(mul_id) do
    Map.put(map, mul_id, unit_type)
  end

  defp put_bf_type(_unit, map), do: map

  defp active_sortie_deployments([]), do: []

  defp active_sortie_deployments(flip_ids) do
    Repo.all(
      from(d in Deployment,
        join: s in Sortie,
        on: s.id == d.sortie_id,
        where: d.company_unit_id in ^flip_ids and s.status in @active_sortie_statuses,
        preload: [:sortie, :pilot, company_unit: :master_unit]
      )
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
