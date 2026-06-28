# Fix: Battle Armor vs Conventional Infantry mis-classification (BFType)

## Summary

The MUL integration mis-classifies **all conventional infantry as battle armor**.
On the MUL both share the same unit *type* (`Type.Id 21`, `Name "Infantry"`); the
only thing that distinguishes them is the **`BFType`** sub-type field (`"BA"` vs
`"CI"`). Our normalization ignores `BFType` and hardcodes `Type.Id 21 →
battle_armor`, so every conventional-infantry record is stored as `battle_armor`.
The type the code *thinks* is conventional infantry — `Type.Id 22` — returns zero
units from MUL.

This affects the cached data in every environment, including **production**,
where it also produces a latent gameplay-rules bug (pilots crewing infantry).

## Root cause

`lib/aces/mul/client.ex`

```elixir
# normalize_unit/2
unit_type: resolve_unit_type(api_data["Type"]),   # api_data["Type"] = %{"Id"=>21,"Name"=>"Infantry"} for BOTH

@type_id_mappings %{
  18 => "battlemech",
  19 => "combat_vehicle",
  20 => "protomech",
  21 => "battle_armor",          # <- actually the whole "Infantry" supertype (BA + CI)
  22 => "conventional_infantry"  # <- unused; MUL returns nothing for Types=22
}
```

The same wrong mapping is duplicated in the two seeding entry points:

- `lib/mix/tasks/seed_master_units.ex:51-60` (`@type_mappings`)
- `lib/aces/release.ex:21-30` (`@type_mappings`) — **the production seeding path**

Verified against the live MUL API:

- `Types=22` → 0 units (every era/faction combination, and unfiltered).
- `Types=21` + `Factions=34` (mercenary) + `AvailableEras=257` (IlClan) → 173
  units, split by `BFType`: **98 `BA`, 70 `CI`**, 4 `ba`, 1 `nil`.
- Name search confirms real CI exists with `BFType "CI"` (e.g. `Foot Platoon
  (Flamer)` id 1143, `Mechanized Tracked Platoon (MG)` id 2141).

So roughly **40% of everything currently typed `battle_armor` is really
conventional infantry.**

## Data model gap

`master_units` does **not** persist `BFType`. Given a cached row typed
`battle_armor`, we cannot tell locally whether it is genuinely BA or mislabeled
CI. Correcting existing data therefore requires **re-fetching from MUL** (which
returns `BFType`). Persisting `bf_type` going forward removes this blind spot.

## App ramifications

1. **Pilots on infantry (rules-correctness bug — highest priority).**
   - `lib/aces/companies/pilot.ex:20` — `@valid_pilot_unit_types ~w(battlemech
     combat_vehicle battle_armor)`; conventional infantry is intentionally
     excluded.
   - `lib/aces_web/live/sortie_live/new.ex:387` and `.../edit.ex:446` hide pilot
     assignment when `unit.master_unit.unit_type == "conventional_infantry"`.
   - Because a mislabeled CI row presents as `battle_armor`, the UI **allows
     crewing it with a pilot**. After correction these `company_units.pilot_id`
     values violate the rule and must be cleared; any pilot created as
     `battle_armor` crew for them is left without a valid unit.
2. **Discoverability / filtering (cosmetic).**
   - `lib/aces_web/live/components/unit_search_modal.ex:434-439` and
     `lib/aces_web/live/company_live/draft.ex:843-844` — infantry never shows
     under the "Infantry" filter; it hides under "Battle Armor".
3. **Composition / deployment logic (low impact).**
   - `lib/aces/companies/company_unit.ex:41` (`@allowed_unit_types`) and
     `lib/aces/campaigns/deployment.ex:125` treat both as non-mech, so rule
     application is largely unaffected by the relabeling.

## Plan

### Phase 1 — Client classification + persist BFType ✅ done (commit 104c16b)

- [x] `client.ex`: change `normalize_unit` so `unit_type` is derived with access
      to `BFType`. When `Type.Id == 21` (or `Type.Name == "Infantry"`), map
      `BFType` case-insensitively: `"ci" → conventional_infantry`, otherwise
      `battle_armor`. Keep `18/19/20` as-is. Remove the bogus `22` mapping and
      fix the comment.
- [x] `client.ex`: add `bf_type: api_data["BFType"]` to the normalized map.
- [x] Migration: add `bf_type :string` (nullable) to `master_units`.
- [x] `Aces.Units.MasterUnit`: add `bf_type` field + include in `changeset` cast.
- [x] Tests: normalization of a `BFType "CI"` payload → `conventional_infantry`;
      `BFType "BA"` → `battle_armor`; non-infantry types unchanged.
      (`test/aces/mul/client_test.exs`; `normalize_unit/1` exposed as the seam.)

### Phase 2 — Fix seeding entry points ✅ done (commit 104c16b)

- [x] `seed_master_units.ex` and `release.ex`: update `@type_mappings` so
      infantry resolves to MUL type `21` (the "Infantry" supertype). Stored
      `unit_type` then comes from `BFType`, not the request. Drop `22`.
- [x] CLI ergonomics **decided**: collapse to a single `infantry` keyword (→ 21).
      The old `battle_armor`/`conventional_infantry` fetch keywords were dropped
      — after the BFType split they were misleading (they never filtered to one
      category; a Type-21 fetch always returns both BA and CI). One honest
      keyword fetches all infantry; storage splits by `BFType`.
- [x] Update `specs/MUL_INTEGRATION.md` to reflect the BA/CI/BFType reality.

### Phase 3 — Correct existing data (dry-run-first; reusable for prod)

#### Findings — how the "CI can't have a pilot" rule is (not) enforced

Investigated before writing the correction task. The rule is **not enforced at
the data layer** — only partially, and inconsistently, in the UI:

- **No DB constraint.** `company_units.pilot_id` is just
  `references(:pilots, on_delete: :nilify_all)` with a uniqueness index
  (`company_units_pilot_assignment_unique`, one pilot → one unit). Nothing ties
  pilot eligibility to the unit's `unit_type`.
- **No changeset validation.** `CompanyUnit.changeset/2` freely casts
  `:pilot_id`. `Pilot`'s own `unit_type` is constrained to
  `battlemech | combat_vehicle | battle_armor` — but that is the *pilot's*
  qualification, not a check on *which unit* it crews.
- **UI enforcement is split and incomplete.** Sortie `new.ex` / `edit.ex` hide
  the pilot picker for `conventional_infantry`, but the roster
  `AcesWeb.CompanyLive.UnitEditComponent` shows the pilot dropdown for **any**
  unit with no type gating. So even a *correctly* typed CI unit can be given a
  pilot today via the roster editor.

**What this means for a mislabeled CI unit that already has a pilot:**

- *Today* (unit still typed `battle_armor`): the user can and does assign a
  pilot — every UI treats it as battle armor, so it "just works", no error.
- *After re-typing to `conventional_infantry` without clearing the link:*
  nothing crashes. The FK stays valid and `CompanyUnit.effective_skill_level/1`
  returns the assigned pilot's skill for a CI unit — a **silent rules
  violation**. The roster editor will still let you (re)assign a pilot to it.
- The **pilot itself survives**: its `unit_type` stays `battle_armor` (valid);
  it simply becomes unassigned and the owner can re-crew a real BA unit.

**The trap: there are TWO independent pilot links.**

1. `company_units.pilot_id` — the roster "default crew".
2. `deployments.pilot_id` — a **separate** per-sortie crew record, plus
   mid-sortie `pilot_allocations` (SP earned, wounds).

Clearing #1 does **not** touch #2. For any **in-flight sortie** where a now-CI
unit is deployed with a pilot, nulling only the roster link leaves a deployment
+ allocations still crewing it; auto-mutating that would corrupt active game
state. Hence: report/flag active sorties, never auto-fix them.

#### 3a — Enforce the rule so corrected data can't immediately re-break

Without this, Phase 3's correction is undone the moment an owner opens the
roster editor on a corrected unit. Do this **before** the data correction.

- [ ] `CompanyUnit`: reject `pilot_id` when the assigned master unit is
      `conventional_infantry` (changeset validation; covers the roster editor,
      which currently has no type gate). Add a matching error message.
- [ ] `UnitEditComponent`: hide/disable the pilot dropdown for
      `conventional_infantry` units, matching the sortie views.
- [ ] Optional belt-and-braces: a DB check/trigger is awkward (the type lives on
      `master_units`, not `company_units`), so prefer the changeset guard;
      revisit a constraint only if we see drift.
- [ ] Tests: assigning a pilot to a CI `company_unit` is rejected.

#### 3b — Correction task (dry-run-first; reusable for prod)

Implement as a mix task **and** an `Aces.Release` function (prod has no Mix).

- [ ] **Dry run (default):** for each distinct era/faction the env was seeded
      with (or a configurable set), fetch the Type-21 list, build a
      `mul_id → BFType` map, and report how many cached `battle_armor` rows would
      flip to `conventional_infantry`, plus the list of affected `company_units`
      (with `pilot_id` set) **and** any active sorties whose `deployments`
      reference them (with `deployments.pilot_id` / live `pilot_allocations`).
- [ ] **Apply:** in a transaction —
  1. Update mislabeled `master_units` rows → `conventional_infantry`, set
     `bf_type`.
  2. Clear `pilot_id` on `company_units` now pointing at infantry; log each
     `{company, unit, pilot}` cleared.
  3. Report pilots whose `unit_type == "battle_armor"` that are now unassigned
     (no destructive change — owners can reassign/retrain).
  4. **Flag, do not mutate, active sorties/deployments** referencing corrected
     units (`deployments.pilot_id` and any open `pilot_allocations` are left
     untouched). Emit a per-sortie review list so a human can resolve live game
     state manually.
- [ ] Safety: never delete `master_units` (rows may be referenced by
      `company_units`); only re-type. Guard with an explicit `--apply` flag and
      print a summary + counts before and after.

### Phase 4 — Verification & rollout

- [ ] Order matters: ship **3a (enforcement)** before running **3b
      (correction)** in any environment, so corrected rows can't be re-broken by
      the roster editor between correction and deploy.
- [ ] Local: run dry-run, confirm counts match the ~40% estimate, apply, spot
      check a known CI unit (e.g. mul_id 1143) is now `conventional_infantry`,
      and confirm its roster `pilot_id` was cleared and the editor no longer
      offers a pilot for it.
- [ ] Backfill `bf_type` for non-infantry rows opportunistically on next seed
      (optional; not required for correctness).
- [ ] Prod: snapshot/backup DB → deploy 3a enforcement → run dry-run → **review
      the active-sortie flag list and resolve any live deployments/allocations
      by hand first** → run `--apply` in a maintenance window → re-verify the
      "Infantry" filter, the roster editor, and the sortie pilot UIs for a
      corrected unit.
- [ ] After correction, notify affected company owners (see Notes): some pilots
      are now unassigned, and any sortie that was mid-flight with a corrected
      unit needs an owner decision.

## Notes / open questions

- Pilot retraining: a pilot left unassigned after correction keeps its
  `unit_type: "battle_armor"`. That's valid; no schema change needed. Consider a
  one-time in-app notice to affected company owners — covering both the newly
  unassigned pilots **and** any sortie that was mid-flight with a corrected unit
  (those need an owner decision; Phase 3b only flags them).
- Enforcement gap (see Phase 3 findings): the "CI can't have a pilot" rule lived
  only in the sortie UIs, not the roster editor or the data layer, so the
  correction needs the 3a guard or it silently regresses.
- The `mix seed_dev` task already sidesteps this bug by baking in correctly-typed
  canonical BA/CI (`lib/mix/tasks/seed_dev.ex`), so it is unaffected and can stay.
- `master_units.name` for infantry currently comes from `Class` (e.g. "Foot
  Platoon") via `normalize_unit` (`name: api_data["Class"] || api_data["Name"]`);
  the seed_dev canonical rows use the full `Name`. Harmonize if desired, but not
  required for this fix.
