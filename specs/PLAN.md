# Battletech: Aces Campaign Tracker - Implementation Plan

## Overview

Build a Phoenix/LiveView web application to digitize the Battletech: Aces campaign log sheets, enabling players to manage their mercenary companies, track pilots, run sorties, and collaborate with friends in real-time.

## Core Requirements

### User Decisions
- **Campaign Data**: Manual campaign creation (users enter sortie details)
- **Unit Data**: Seeded database from masterunitlist.info (IlClan era, Mercenaries availability list)
- **Starting Warchest**: User-defined when creating campaign (flexible for different campaign types)
- **Multiplayer**: Shared company ownership with real-time LiveView updates
- **Game Tracking**: Post-sortie results only (physical game → input results)
- **UI Framework**: TailwindCSS + daisyUI component library

### Key Features
1. Mercenary company management with unit roster
2. Named pilots with skill progression, edge abilities, wound tracking
3. Campaign tracking with warchest (SP currency) management
4. Sortie mission tracking with income/expense calculations
5. Post-sortie processing: casualties, salvage, MVP awards, SP allocation
6. Unit purchasing from masterunitlist.info database
7. Memorial wall for lost units and fallen pilots
8. Multi-user collaboration with real-time updates

## Database Schema

### Core Entities & Relationships

```
Users (phx.gen.auth)
  ↓
CompanyMemberships (join table with roles: owner/editor/viewer)
  ↓
Companies
  ├── Pilots (callsign, skill_level, edge_tokens, edge_abilities, status, wounds, mvp_awards)
  │   └── PilotCampaignStats (sp_earned, sorties_participated per campaign)
  ├── CompanyUnits (custom_name, status, purchase_cost_sp)
  │   └── belongs_to MasterUnit (seeded from MUL)
  ├── Campaigns (name, warchest_balance, difficulty_level, pv_multiplier, sp_multiplier, keywords)
  │   └── Sorties (mission_number, mission_name, pv_limit, result, income/expense fields)
  │       └── Deployments (damage_status, pilot_casualty, was_salvaged)
  └── MemorialEntries (entry_type, name, description, lost_on_date)

MasterUnits (seeded from masterunitlist.info API)
  - mul_id, name, variant, chassis, unit_type, point_value, tonnage
  - special_abilities, factions, era, role, introduction_year
```

### Critical Indexes
- `company_memberships`: unique index on `[user_id, company_id]`
- `master_units`: unique index on `mul_id`, indexes on `unit_type`, `point_value`, `chassis`, `name`
- `pilot_campaign_stats`: unique index on `[pilot_id, campaign_id]`
- Foreign key indexes on all associations

## Context Modules (Business Logic)

### `Aces.Accounts`
- User registration, authentication (via phx.gen.auth)

### `Aces.Companies`
- Company CRUD, membership management
- `add_member(company, user, role)` - invite collaborators
- `purchase_unit(company, master_unit, pilot, cost_sp)` - add unit to roster
- Memorial wall operations

### `Aces.Pilots`
- Pilot CRUD, skill progression, edge management
- `calculate_skill_upgrade_cost(from_level, to_level)` - SP costs
- `apply_wound(pilot, severity)` - casualty processing
- Campaign stats tracking

### `Aces.Units`
- Master unit seeding from MUL API
- `seed_master_units_from_mul()` - initial data load
- `search_units(filters)` - type, PV range, faction, era, name

### `Aces.Campaigns`
- Campaign/sortie CRUD, deployment management
- `process_sortie_completion(sortie, results)` - complex post-battle workflow
  - Calculate income (objectives + waypoints + recon) × difficulty modifier
  - Calculate expenses (rearming, personnel, repairs)
  - Process casualties and salvage rolls
  - Distribute SP to pilots
  - Award MVP bonus (+20 SP)
  - Update warchest balance
- `calculate_repair_cost(deployment)` - based on damage_status and unit size
  - Destroyed: 100 SP × size
  - Crippled: 60 SP × size
  - Structure damage: 40 SP × size
  - Armor only: 20 SP × size
  - (Non-'Mechs count as half size)
- `calculate_personnel_cost(deployments)` - 100 SP per wounded/killed, 150 SP replacement

## LiveView Architecture

### Key Pages

**Company Management**
- `CompanyLive.Index` - list user's companies
- `CompanyLive.Show` - company dashboard with tabs: Roster | Campaigns | Memorial
  - PubSub: `"company:#{company_id}"`

**Campaign & Sortie**
- `CampaignLive.Show` - campaign overview, warchest, sortie history
  - PubSub: `"campaign:#{campaign_id}"`
- `SortieLive.New` - multi-step wizard: mission details → unit deployment → reconnaissance → review
- `SortieLive.Show` - sortie details, deployment roster, income/expense breakdown
- `SortieLive.PostBattle` - **complex multi-step form**:
  1. Mark unit damage levels
  2. Casualty rolls (wounded/killed)
  3. Salvage rolls
  4. Select MVP
  5. Allocate SP to pilots
  6. Purchase new units (optional)
  7. Summary and commit

**Pilots & Units**
- `PilotLive.Index` - pilot roster with cards
- `PilotLive.Show` - detailed pilot view, skill progression calculator, campaign history
- `UnitBrowserLive.Index` - browse/search master units, add to roster
- `MemorialLive.Index` - memorial wall display

### Reusable Components
- `UnitCardComponent` - unit info card with assign pilot action
- `PilotCardComponent` - pilot stats with skill progression chart
- `DeploymentRowComponent` - sortie deployment with inline damage/casualty edit
- `SPCalculatorComponent` - interactive SP allocation with cost preview
- `WarchestWidgetComponent` - live balance display with PubSub updates
- `UnitFilterComponent` - advanced filtering (type, PV range, era, faction)

### Real-time Collaboration
- Subscribe to PubSub topics in mount
- Broadcast after state changes: `{:unit_added, company_unit}`, `{:warchest_updated, new_balance}`, etc.
- Optimistic UI updates for instant feedback

## Authentication & Authorization

### Setup
Run `mix phx.gen.auth Accounts User users` to generate:
- User registration/login
- Password hashing (bcrypt)
- Email confirmation
- Session management
- LiveView authentication helpers

### Authorization Layer
`Aces.Companies.Authorization` module with:
- `can?(:view_company, user, company)` - check membership
- `can?(:edit_company, user, company)` - check owner/editor role
- `can?(:manage_members, user, company)` - owner only

Enforce in LiveView mount:
```elixir
if Companies.Authorization.can?(:view_company, user, company) do
  Phoenix.PubSub.subscribe(Aces.PubSub, "company:#{company_id}")
  {:ok, assign(socket, company: company)}
else
  {:ok, redirect(socket, to: ~p"/companies")}
end
```

## MasterUnitList.info Integration

### Seeding Strategy
Create mix task: `lib/mix/tasks/seed_master_units.ex`
- Fetch from MUL API: `https://masterunitlist.azurewebsites.net/Unit/QuickList`
- **Focus on IlClan era units with Mercenaries availability** (default for Aces campaigns)
- Parse and bulk insert into `master_units` table
- Store essential fields: mul_id, name, variant, PV, unit_type, tonnage, special_abilities, factions, availability
- Run once at setup: `mix seed_master_units`
- Optional: Add `--era` and `--faction` flags for custom filtering
- Optional periodic refresh for new units

### MUL API Client Module
`Aces.MUL.Client` with:
- `fetch_units(filters)` - query API with type/tonnage/faction filters
- `fetch_unit_details(mul_id)` - detailed unit info
- Use `Req` HTTP client (already in deps)

## Implementation Phases

### Phase 1: Foundation (MVP Core)
1. Add daisyUI to `assets/tailwind.config.js` dependencies
2. Run `mix phx.gen.auth Accounts User users`
3. Create all migrations (companies, pilots, units, campaigns, sorties, deployments)
4. Build company index/show LiveViews with daisyUI components
5. Seed master units from MUL (IlClan era, Mercenaries availability)
6. Build unit browser with search and filters
7. Implement unit purchasing

**Deliverable**: Users can create companies, browse units, build roster

### Phase 2: Pilot Management
1. Pilot CRUD LiveViews
2. Skill progression calculator
3. Pilot card components

**Deliverable**: Full pilot management with skill tracking

### Phase 3: Campaign & Sortie Tracking
1. Campaign/sortie schemas and contexts
2. Campaign show LiveView
3. Sortie creation wizard
4. Deployment system
5. Pilot-unit assignment
6. Sortie in-progress view (mark units as damaged/crippled/destroyed, pilots as wounded/killed)
7. Income/expense forms
8. Warchest calculations

**Deliverable**: Track campaigns and sorties with financial management

### Phase 4: Post-Battle Processing
1. Post-battle multi-step LiveView
2. Damage/casualty processing
3. Salvage mechanics
4. MVP selection
5. SP allocation interface
6. Unit purchasing flow

**Deliverable**: Full sortie completion workflow

### Phase 5: Real-time Collaboration
1. PubSub broadcasts for all updates
2. Real-time updates in all LiveViews
3. Company invitation system
4. Permission enforcement
5. Optimistic UI updates

**Deliverable**: Multi-user collaborative editing

### Phase 6: Memorial & Polish
1. Memorial wall
2. Pilot campaign history
3. Campaign summary reports
4. Sortie history timeline
5. UX improvements (loading states, confirmations, error handling)

**Deliverable**: Complete historical tracking and polished UX

## Critical Business Logic

### Skill Progression Costs

Pilots gain SP as they participate in Sorties, up to an amount specified by the Sortie (this needs to be entered by players after the Sortie finishes). Pilots that did not participate in the Sortie get half this amount. The SP to "pay" the pilots comes out of the Sortie rewards, and must be paid, or the amount pulled from the Detachment's Warchest.

Pilots can then have their SP allocated to Skill, Edge Tokens, or Edge Abilities. The SP earned can be allocated any way the player desires between these three pools.

Pilots must start at skill 4. In Alpha Strike, lower skill is better.
Going to skill 3 requires 400 SP allocated to Skill.
Going to skill 2 requires 900 SP allocated to Skill.
Going to skill 1 requires 1900 SP allocated to skill.
Going to skill 0 requires 3400 SP allocated to Skill.
Pilots cannot go below Skill 0.

Pilots allocating points to Edge Tokens at the end of a Sortie follow the following progression:
2 - 60 SP
3 - 120 SP
4 - 200 SP
5 - 300 SP
6 - 420 SP
7 - 560 SP
8 - 720 SP
9 - 900 SP
10 - 1100 SP

Pilots allocating points to Edge Abilities get the following number of Edge Abilities at each threshold:
1 - 60 SP
2 - 180 SP
3 - 360 SP
4 - 600 SP
5 - 900 SP

Pilots start with 150 SP and must immediately allocate their SP to the three pools, above. Pilots start at Skill 4, 1 Edge Token, and 0 Edge Abilities.


### Unit Purchase Cost
```elixir
cost_sp = master_unit.point_value * 40
```

### Repair Cost Calculation
If a unit was Destroyed it requires SP equal to its Size * 100 to repair.
If a unit was crippled it costs Size * 60 SP to repair.
If a unit has any other amount of internal structure damage or critical hits: Size * 40 SP.
If a unit only has armour damage, Size * 20 SP to repair.

Combst Vehicles, Battle Armour, and Conventional Infantry count as half their size for the purposes of repair costs (e.g. divide their Size by 2 first, and do not round off! Repairing a crippled size 3 tank costs 1.5 * 60 SP)

### Sortie Earnings
```elixir
total_income = (primary_objective + secondary_objectives + waypoints - reconnaissance_cost) * difficulty_multiplier
total_expenses = rearming_cost + personnel_cost + repair_cost
net_earnings = total_income - total_expenses
new_warchest_balance = campaign.warchest_balance + net_earnings
```

## Testing Strategy

### Critical Test Cases
- SP calculation accuracy (skill costs, repair costs, personnel costs)
- Warchest balance integrity (no SP loss/duplication)
- Pilot skill progression (correct costs at each level)
- Damage repair cost formula (all unit types and damage states)
- Sortie completion workflow end-to-end
- Concurrent user updates (race conditions)
- Cannot deploy same unit twice in one sortie
- Cannot spend more SP than available
- Warchest never goes negative

### Test Coverage
- Context layer: business logic unit tests
- LiveView layer: integration tests with `Phoenix.LiveViewTest`
- Property-based testing for SP calculations (StreamData)

## Technical Considerations

### PubSub Events
Topics: `"company:#{id}"`, `"campaign:#{id}"`, `"sortie:#{id}"`

Events:
- `{:unit_added, company_unit}`
- `{:pilot_updated, pilot}`
- `{:warchest_updated, new_balance}`
- `{:sortie_completed, sortie}`
- `{:deployment_updated, deployment}`

### Database Query Optimization
Use preloading to avoid N+1:
```elixir
Campaign
|> preload([
  :company,
  sorties: [deployments: [:company_unit, :pilot]]
])
|> Repo.get!(id)
```

### UI/UX Patterns
- Desktop-focused (wide forms, multi-column layouts)
- **TailwindCSS + daisyUI component library**
- daisyUI components to use:
  - `card` for units/pilots
  - `table` for sortie history and rosters
  - `modal` for confirmations and dialogs
  - `badge` for status indicators (wounded, destroyed, etc.)
  - `tabs` for navigation (Roster | Campaigns | Memorial)
  - `btn` with variants (primary, secondary, ghost)
  - `form-control` for inputs
  - `stat` for warchest display
- Real-time validation with `phx-change`
- Loading states with daisyUI `loading` spinner
- Error handling with `alert` component
- Keyboard shortcuts for power users

## Critical Files for Implementation

**Database:**
- `priv/repo/migrations/` - all schema migrations
- `priv/repo/seeds.exs` - master unit seeding

**Contexts:**
- `lib/aces/companies.ex` - core domain logic
- `lib/aces/campaigns.ex` - complex SP calculations
- `lib/aces/pilots.ex` - skill progression
- `lib/aces/units.ex` - MUL integration

**LiveViews:**
- `lib/aces_web/live/company_live/show.ex` - company dashboard
- `lib/aces_web/live/sortie_live/post_battle.ex` - complex multi-step form
- `lib/aces_web/live/campaign_live/show.ex` - campaign overview

**Components:**
- `lib/aces_web/live/components/` - reusable UI components

## Setup & Configuration

### 1. Add daisyUI to TailwindCSS
Edit `assets/tailwind.config.js`:
```javascript
module.exports = {
  plugins: [
    require("@tailwindcss/forms"),
    require("daisyui")
  ],
  daisyui: {
    themes: ["light", "dark", "cyberpunk"], // Choose themes
  },
}
```

Install daisyUI:
```bash
cd assets && npm install -D daisyui@latest
```

Testing: Generate a page that the user can visit to see a bunch of daisyui components together, to assert that this is working correctly, and to give the user an idea what these components look like. This should be a Phoenix LiveView that also shows what other users are doing with those components on the same page.

### 2. MasterUnitList Seeding
The mix task should filter for:
- **Era**: IlClan (3151+)
- **Availability**: Mercenaries faction availability
- **Optional flags**: `--all-eras`, `--faction <name>` for flexibility

## Next Steps

1. Add daisyUI to TailwindCSS configuration
2. Run `mix phx.gen.auth Accounts User users`
3. Create all database migrations in order
4. Build context modules with business logic
5. Create MUL seeding mix task (IlClan era, Mercenaries availability)
6. Seed master units from MUL API
7. Build LiveViews following phased approach
8. Implement PubSub for real-time collaboration
9. Add comprehensive tests for critical calculations
10. Polish UX with daisyUI components and loading states
