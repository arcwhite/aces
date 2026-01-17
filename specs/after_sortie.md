# After Sortie: Completion Workflow

This document describes the multi-step wizard for completing a Sortie after the game has been played.

## Overview

When a Sortie is finished (the tabletop game is over), players need to record the outcome and resolve various bookkeeping tasks. This is a sequential wizard implemented as separate LiveViews, with progress saved at each step so users can resume if interrupted.

## Sortie Status Flow

```
setup → in_progress → finalizing → completed
                   ↘ failed (can retry as new sortie)
```

The `finalizing` status is new - it indicates the sortie game is over but the bookkeeping wizard hasn't been completed yet.

## Entry Point

From `sortie_live/show.ex`, when a sortie is `in_progress`, show two buttons:

### "Sortie Failed" Button

Opens a simple confirmation modal (or inline form) with:
- Optional notes field for what went wrong
- Confirm/Cancel buttons

On confirm:
- Set sortie status to `failed`
- Record a `sortie_failed` event
- Redirect back to campaign page with flash message

The deployment data (damage tracked during play) stays as historical record, but none of it is applied to the Company - no unit status changes, no pilot wounds/deaths, no income or expenses. The failed sortie remains visible in the campaign history. Players can create a new sortie to retry the mission.

### "Sortie Victory" Button

Transitions the sortie to `finalizing` status and redirects to Step 1 of the completion wizard.

## Data Model Changes

### Sortie Schema Additions

```elixir
# New fields on Sortie
field :outcome, :string  # "success" | "failure" | nil
field :outcome_keywords, {:array, :string}, default: []
field :base_income_sp, :integer  # Income before difficulty adjustment
field :pilot_sp_max, :integer    # Max SP each named pilot can earn
field :waypoint_adjustments_sp, :integer, default: 0  # +/- SP from waypoints
field :finalization_step, :string  # Tracks wizard progress: "outcome" | "damage" | "costs" | "pilots" | "summary" | nil
field :finalization_data, :map, default: %{}  # Stores intermediate wizard state
field :mvp_pilot_id, references(:pilots)
```

### Deployment Schema Additions

```elixir
# Confirm whether a destroyed unit passed its salvage check
field :is_salvageable, :boolean, default: false

# Track the final confirmed status (may differ from in-game tracking)
field :final_damage_status, :string  # Same enum as damage_status
field :final_pilot_casualty, :string  # Same enum as pilot_casualty
```

### Pilot Schema (Already Exists)

The Pilot schema already has the fields we need:

```elixir
field :status, :string, default: "active"  # "active" | "wounded" | "deceased"
field :wounds, :integer, default: 0
field :mvp_awards, :integer, default: 0
field :sorties_participated, :integer, default: 0
field :sp_earned, :integer, default: 0
```

No changes needed to Pilot schema.

### CompanyUnit Schema (Already Exists)

The CompanyUnit schema already has a status field:

```elixir
@valid_statuses ~w(operational damaged destroyed salvaged)
field :status, :string, default: "operational"
```

After sortie completion:
- Units that were destroyed but passed salvage check → `salvaged` (can be repaired)
- Units that were destroyed and failed salvage check → `destroyed` (total loss, cannot deploy)
- Units that were damaged (any level) and repaired → `operational`

The `destroyed` status means the unit is permanently lost. The `salvaged` status is temporary until repairs are paid, then it returns to `operational`.

## Wizard Steps

### Step 1: Victory Details (`/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/outcome`)

**Purpose**: Record income and rewards from the successful sortie.

**UI Elements**:
- **Keywords Earned**: Text input to add keywords (can add multiple, shown as tags)
- **Base Income SP**: Number input for income earned from the sortie
- **Waypoint Adjustments**: Number input (+/-) for any waypoint gains/losses
- **Max SP Per Pilot**: Number input (from the mission description in sourcebook)
- **Notes**: Optional textarea for mission notes

**Difficulty Adjustment Display**:
Show the player a breakdown:
- Base Income: X SP
- Difficulty Modifier: ±Y% (based on campaign difficulty)
- Adjusted Income: Z SP

**On Submit**:
- Save outcome data to sortie (outcome = "success")
- Set `finalization_step` to "damage"
- Redirect to Step 2

---

### Step 2: Confirm Unit Status (`/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/damage`)

**Purpose**: Confirm final damage status for all deployed units.

**UI Elements**:
For each deployment, show:
- Unit name and pilot name
- Current damage status (from in-game tracking)
- Dropdown to adjust final damage status if needed
- If status is "destroyed": checkbox "Passed Salvage Check (Salvageable)"
- Current pilot/crew casualty status
- Dropdown to adjust final casualty status if needed

**Validation**:
- All units must have a confirmed final status
- Destroyed units must have salvageable checkbox explicitly set (true or false)

**On Submit**:
- Save `final_damage_status`, `final_pilot_casualty`, and `is_salvageable` to each deployment
- Set `finalization_step` to "costs"
- Redirect to Step 3

---

### Step 3: Costs & Expenses (`/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/costs`)

**Purpose**: Calculate and display all repair, re-arming, and casualty costs.

**Calculations** (all automated, displayed for review):

#### Repair Costs
For each unit, calculate Repair Size:
- BattleMechs: Size
- Combat Vehicles, Battle Armor, Infantry: Size / 2

Then apply repair cost based on final_damage_status:
| Status | Cost |
|--------|------|
| Operational | 0 SP |
| Armor Damaged | Repair Size × 20 SP |
| Structure Damaged | Repair Size × 40 SP |
| Crippled | Repair Size × 60 SP |
| Salvageable | Repair Size × 100 SP |
| Destroyed (not salvageable) | Unit is lost, no repair cost |

#### Re-arming Costs
- 20 SP per unit that went on the sortie
- Units with "ENE" in their `bf_abilities` are exempt
- Display which units are exempt

#### Casualty Costs
For each deployment with casualties:
- Non-named crew wounded/killed: 100 SP (to heal or replace)
- Named pilot wounded: 100 SP + mark pilot as wounded (sits out next sortie)
- Named pilot killed: No cost, but pilot is removed from company

**UI Elements**:
- Summary table showing all units and their costs
- Section for crew/pilot casualties and costs
- Totals section:
  - Total Repair Costs: X SP
  - Total Re-arming Costs: Y SP
  - Total Casualty Costs: Z SP
  - **Total Expenses: W SP**
- Net calculation:
  - Adjusted Income: A SP
  - Total Expenses: B SP
  - **Net Earnings: C SP** (can be negative!)

**On Submit**:
- If net earnings < 0:
  - Deduct from company warchest
  - If warchest would go negative, warn but allow (debt tracking?)
- Store calculated costs in `finalization_data`
- Set `finalization_step` to "pilots"
- Redirect to Step 4

---

### Step 4: Pilot SP Distribution (`/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/pilots`)

**Purpose**: Distribute SP earnings to named pilots and allocate their new SP.

**Earnings Distribution Logic**:

1. Calculate total SP available for pilots:
   - If net earnings > 0: Use net earnings for pilot pay
   - If net earnings ≤ 0: Pilots earn nothing from this sortie

2. Determine each pilot's share:
   - Pilots who participated: up to `pilot_sp_max` each
   - Pilots who did NOT participate: up to `pilot_sp_max / 2` each
   - Wounded pilots still earn their share
   - Killed pilots earn nothing
   - If total shares exceed available SP, divide evenly

3. MVP Selection:
   - Player selects one participating pilot as MVP
   - MVP receives +20 SP bonus (does NOT come from earnings/warchest)

**UI Elements**:

**Section 1: SP Distribution**
- Show available SP for distribution
- For each named pilot in company:
  - Name, callsign, participation status
  - Calculated SP share
  - If killed, show "Killed in action - no SP earned"
- MVP dropdown (only participating, living pilots)
- Show MVP bonus: +20 SP

**Section 2: Allocate Pilot SP** (for each pilot earning SP)
- Award MVP bonus here
For each pilot, show their current SP pools and allow allocation:
- Current Skill Level (with SP invested)
- Current Edge Tokens (with SP invested)
- Current Edge Abilities (with SP invested)
- SP to allocate: [their share + MVP bonus if applicable]
- Allocation inputs for each pool

**Validation**:
- All SP must be allocated (cannot leave SP unspent)
- Skill level increases must follow the SP cost table
- Edge abilities must be valid selections

**On Submit**:
- Apply SP to each pilot's pools as the user specified
- Mark wounded pilots as wounded
- Mark killed pilots as deceased
- Record any keyword changes from the Sortie against the Campaign
- Set `finalization_step` to "summary"
- Redirect to Step 5

---

### Step 5: Summary & Warchest (`/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/summary`)

**Purpose**: Show complete summary and finalize the sortie.

**UI Elements**:

**Sortie Summary Card**:
- Sortie name and mission number
- Outcome: Success/Failure
- Keywords earned
- Duration (started_at to completed_at)

**Financial Summary**:
- Base Income: X SP
- Difficulty Adjustment: ±Y%
- Adjusted Income: Z SP
- Waypoint Adjustments: ±W SP
- Total Expenses: -E SP
- **Net Result: N SP**

**Unit Status Summary**:
Table showing each unit's final status and repair cost

**Pilot Summary**:
- SP distributed to pilots
- MVP: [Pilot Name] (+20 SP bonus)
- Pilots wounded (sitting out next sortie)
- Pilots killed in action

**Warchest Update**:
- Previous Warchest: X SP
- Added from Sortie: Y SP (remaining after pilot pay)
- **New Warchest Total: Z SP**

**Actions**:
- "Complete Sortie" button to finalize
- This summary should remain viewable after completion

**On Submit**:
- Update company warchest
- Set sortie status to `completed`
- Set `completed_at` timestamp
- Clear `finalization_step` (or set to "complete")
- Record events for all significant changes
- Heal any pilots who were wounded from PREVIOUS sorties (not this one)
- Redirect to campaign page

---

## Navigation & Progress Saving

### URL Structure
```
/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/outcome
/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/damage
/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/costs
/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/pilots
/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/summary
```

### Progress Tracking
- Each step saves to the database on submit
- `finalization_step` tracks current progress
- `finalization_data` stores intermediate calculations (JSON map)
- If user navigates away and returns, resume at their current step
- Back buttons allow revisiting previous steps (with warning about losing changes)

### Authorization
- Same authorization as editing the sortie (`can?(:edit_company, user, company)`)
- Only accessible when sortie is in `in_progress` or `finalizing` status

---

## Events to Record

For the timeline/history feature, record these events:

- `sortie_completed` - Sortie finished successfully
- `sortie_failed` - Sortie ended in failure
- `unit_destroyed` - Unit was destroyed and not salvageable
- `unit_salvaged` - Destroyed unit passed salvage check
- `unit_repaired` - Unit was repaired (with cost)
- `pilot_wounded` - Named pilot was wounded
- `pilot_killed` - Named pilot was killed in action
- `pilot_healed` - Pilot recovered from wounds
- `pilot_sp_earned` - Pilot earned SP from sortie
- `pilot_mvp` - Pilot was named MVP
- `warchest_updated` - Company warchest changed

---

## Edge Cases

### No Named Pilots Participated
- Cannot complete sortie (should be blocked at sortie start)
- But if somehow reached, skip MVP selection

### All Pilots Killed
- No SP distribution needed
- Company may need to hire new pilots before next sortie
- Show warning about company viability

### Negative Net Earnings
- Deduct from warchest
- If warchest goes negative, allow it (track as debt)
- Show prominent warning about financial situation

### Destroyed Units (Not Salvageable)
- Remove from company roster? Or mark as destroyed?
- Recommend: Mark with `status: "destroyed"` on CompanyUnit, don't delete

---

## Implementation Order

1. Add new schema fields (Sortie, Deployment) - Pilot and CompanyUnit already have needed fields
2. Create migration
3. Add "Sortie Failed" button + modal to show.ex (simple flow, no wizard)
4. Extract SP allocation into reusable component from `PilotFormComponent`
5. Implement Step 1 (Victory Details)
6. Implement Step 2 (Damage confirmation)
7. Implement Step 3 (Costs calculation)
8. Implement Step 4 (Pilot SP distribution and allocation, using new component)
9. Implement Step 5 (Summary and finalization)
10. Add "Sortie Victory" button to show.ex (redirects to wizard)
11. Add event recording throughout
12. Update `sortie_live/show.ex` to show summary for completed sorties

---

## Viewing Completed Sorties

When a user navigates to a completed sortie (via `sortie_live/show.ex`), we should:

1. Check if `sortie.status == "completed"`
2. If so, redirect to `/companies/:company_id/campaigns/:campaign_id/sorties/:id/complete/summary`
3. The summary page renders in read-only mode (no "Complete Sortie" button, just the summary)

Alternatively, we could render the summary inline in `show.ex` when the sortie is completed, avoiding the redirect. This might be cleaner UX - the URL stays the same but the content changes based on status.

**Recommendation**: Render summary inline in `show.ex` for completed sorties. This keeps the URL simple and avoids confusing redirects.

---

## Resolved Design Decisions

1. **No undo after completion** - Once recorded, it's recorded. Simplifies the implementation.
2. **Omni-mech variant switching** - Separate feature, not part of this workflow.
3. **Summary is read-only** - Step 5 becomes the permanent record. When viewing a completed sortie, show this summary page.
4. **No print-friendly views** - Not needed for initial implementation.
5. **Killed pilots** - Marked as `status: "deceased"` and added to the Memorial. Not deleted.
6. **Negative warchests** - Allowed. Players can go into debt.
7. **SP allocation UI** - Reuse existing `PilotFormComponent` pattern (see below).

---

## Reusable SP Allocation Component

The existing `AcesWeb.CompanyLive.PilotFormComponent` (`lib/aces_web/live/company_live/pilot_form_component.ex`) contains a full SP allocation UI that we should extract and reuse.

### Current Implementation

The component handles:
- Three SP pools: Skill, Edge Tokens, Edge Abilities
- Real-time calculation of derived stats (skill_level, edge_tokens count)
- Edge ability selection via toggle buttons
- Validation that allocated SP doesn't exceed available SP
- Cost breakdown display for each tier

### Proposed Refactor

Extract the SP allocation portion into a new component:

```
lib/aces_web/components/pilot_sp_allocation.ex
```

This component should accept:
- `pilot` - The pilot struct with current allocations
- `sp_to_allocate` - New SP being added (for after-sortie, this is their earnings + MVP bonus)
- `on_change` - Callback when allocation changes
- `require_full_allocation` - Boolean, if true, all SP must be allocated to proceed

The component renders:
- Current stats summary
- SP allocation inputs for each pool
- Edge ability toggle buttons
- Remaining SP indicator
- Validation errors

### Usage in Step 4

For each pilot earning SP:
```heex
<.live_component
  module={PilotSpAllocation}
  id={"pilot-sp-#{pilot.id}"}
  pilot={pilot}
  sp_to_allocate={pilot_earnings[pilot.id]}
  require_full_allocation={true}
/>
```

The parent LiveView collects all allocations and validates that every pilot has fully allocated their SP before proceeding.
