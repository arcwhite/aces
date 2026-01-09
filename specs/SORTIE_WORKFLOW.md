# Sortie Workflow - In-Progress Tracking & Post-Battle

## Overview

Sorties support **three distinct states** to enable tracking during gameplay:

1. **Setup** - Creating sortie, deploying units
2. **In Progress** - Game being played, updating unit status in real-time
3. **Completed** - Post-battle processing, SP allocation, finalization

---

## Database Support for In-Progress Tracking

### Sortie States

The `sorties` table uses two fields to track completion:

```elixir
field :is_completed, :boolean, default: false  # Has post-battle processing finished?
field :completed_at, :utc_datetime            # When was it finalized?
```

**State Machine:**

```
Created → In Progress → Completed
  ↓           ↓            ↓
Setup     Update       Lock
Phase     Status       Data
```

### Deployment Tracking

The `deployments` table allows **real-time updates during play**:

| Field | Updateable During Play? | Finalized at Completion? |
|-------|------------------------|-------------------------|
| `damage_status` | ✅ Yes - update as damage occurs | ✅ Must be set |
| `pilot_casualty` | ✅ Yes - mark wounded/killed immediately | ✅ Review at end |
| `salvage_roll` | ❌ No - only after destroyed | ✅ Roll at completion |
| `repair_cost_sp` | ❌ No - calculated at completion | ✅ Auto-calculated |

---

## Workflow: Setup Phase

### Step 1: Create Sortie

```elixir
def create_sortie(campaign, attrs) do
  %Sortie{}
  |> Sortie.changeset(attrs)
  |> Repo.insert()
end

# Example attrs:
%{
  campaign_id: 123,
  mission_number: 3,
  mission_name: "Recon Raid",
  pv_limit: 150,
  fictional_date: ~D[3145-08-20],
  pilot_sp_upgrade_limit: 100,  # Each pilot can spend up to 100 SP on skills
  primary_objective_sp: 200,
  secondary_objectives_sp: 50,
  is_completed: false  # Important!
}
```

### Step 2: Deploy Units

```elixir
def deploy_unit(sortie, company_unit, pilot) do
  %Deployment{
    sortie_id: sortie.id,
    company_unit_id: company_unit.id,
    pilot_id: pilot.id,
    damage_status: :none,        # Start undamaged
    pilot_casualty: :none        # Pilot starts healthy
  }
  |> Repo.insert()
end
```

**Validation:**
- Total PV of deployed units ≤ `sortie.pv_limit`
- Cannot deploy same unit twice
- Cannot deploy destroyed units
- Cannot deploy killed pilots

---

## Workflow: In-Progress Phase

### Real-Time Damage Tracking

**Mobile UI (during play):**

```heex
<!-- Quick damage buttons for each deployed unit -->
<div class="deployment-tracker">
  <%= for deployment <- @deployments do %>
    <div class="unit-row">
      <strong><%= deployment.company_unit.master_unit.name %></strong>
      <span class="pilot"><%= deployment.pilot.callsign %></span>

      <!-- Quick damage buttons -->
      <div class="damage-buttons">
        <button
          phx-click="update_damage"
          phx-value-deployment-id={deployment.id}
          phx-value-status="armor_only"
          class={if deployment.damage_status == :armor_only, do: "active"}
        >
          Armor
        </button>

        <button
          phx-click="update_damage"
          phx-value-deployment-id={deployment.id}
          phx-value-status="structure_damage"
          class={if deployment.damage_status == :structure_damage, do: "active"}
        >
          Structure
        </button>

        <button
          phx-click="update_damage"
          phx-value-deployment-id={deployment.id}
          phx-value-status="crippled"
          class={if deployment.damage_status == :crippled, do: "active"}
        >
          Crippled
        </button>

        <button
          phx-click="update_damage"
          phx-value-deployment-id={deployment.id}
          phx-value-status="destroyed"
          class={if deployment.damage_status == :destroyed, do: "active"}
        >
          💥 Destroyed
        </button>
      </div>

      <!-- Pilot casualty (if applicable) -->
      <%= if deployment.damage_status in [:crippled, :destroyed] do %>
        <div class="casualty-check">
          <label>
            <input
              type="radio"
              name={"pilot_#{deployment.id}"}
              value="none"
              phx-click="update_casualty"
              phx-value-deployment-id={deployment.id}
              phx-value-casualty="none"
            /> OK
          </label>
          <label>
            <input
              type="radio"
              name={"pilot_#{deployment.id}"}
              value="wounded"
              phx-click="update_casualty"
              phx-value-deployment-id={deployment.id}
              phx-value-casualty="wounded"
            /> Wounded
          </label>
          <label>
            <input
              type="radio"
              name={"pilot_#{deployment.id}"}
              value="killed"
              phx-click="update_casualty"
              phx-value-deployment-id={deployment.id}
              phx-value-casualty="killed"
            /> Killed
          </label>
        </div>
      <% end %>
    </div>
  <% end %>
</div>

<!-- Summary -->
<div class="battle-summary">
  <p><strong>Units Destroyed:</strong> <%= count_destroyed(@deployments) %></p>
  <p><strong>Pilots Wounded:</strong> <%= count_wounded(@deployments) %></p>
  <p><strong>Estimated Repair Cost:</strong> ~<%= estimate_repair_cost(@deployments) %> SP</p>
</div>

<button
  phx-click="complete_sortie"
  class="btn btn-primary"
  disabled={!can_complete?(@sortie)}
>
  Complete Sortie →
</button>
```

### LiveView Handlers

```elixir
def handle_event("update_damage", %{"deployment-id" => id, "status" => status}, socket) do
  deployment = Campaigns.get_deployment!(id)

  # Update damage status (allowed during play)
  Campaigns.update_deployment(deployment, %{
    damage_status: String.to_existing_atom(status)
  })

  # Broadcast to other players viewing this sortie
  Phoenix.PubSub.broadcast(
    Aces.PubSub,
    "sortie:#{socket.assigns.sortie.id}",
    {:deployment_updated, deployment.id}
  )

  {:noreply, reload_deployments(socket)}
end

def handle_event("update_casualty", %{"deployment-id" => id, "casualty" => casualty}, socket) do
  deployment = Campaigns.get_deployment!(id)

  Campaigns.update_deployment(deployment, %{
    pilot_casualty: String.to_existing_atom(casualty)
  })

  Phoenix.PubSub.broadcast(
    Aces.PubSub,
    "sortie:#{socket.assigns.sortie.id}",
    {:deployment_updated, deployment.id}
  )

  {:noreply, reload_deployments(socket)}
end
```

### Multi-Session Support

If a sortie spans multiple play sessions:

```elixir
# Session 1: Setup and start playing
sortie = create_sortie(campaign, attrs)
deploy_units(sortie, [unit1, unit2, unit3])
# Players update damage as they play...
# Save and exit

# Session 2: Resume where left off
sortie = get_sortie!(sortie_id)  # is_completed = false
deployments = list_deployments(sortie)  # Shows saved damage status
# Continue playing, updating damage...
```

**Key point:** `is_completed = false` means the sortie is **still active and editable**.

---

## Workflow: Post-Battle Completion

### Step 1: Trigger Completion

```elixir
def handle_event("complete_sortie", _params, socket) do
  sortie = socket.assigns.sortie

  # Validate all required data is present
  case validate_sortie_ready_for_completion(sortie) do
    :ok ->
      {:noreply, push_navigate(socket, to: ~p"/sorties/#{sortie}/post-battle")}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, reason)}
  end
end

defp validate_sortie_ready_for_completion(sortie) do
  cond do
    sortie.result == nil ->
      {:error, "Please set mission result (Victory/Defeat)"}

    has_unresolved_casualties?(sortie) ->
      {:error, "Please resolve all pilot casualties"}

    true ->
      :ok
  end
end
```

### Step 2: Post-Battle Multi-Step Wizard

**Mobile-optimized steps:**

```
Step 1: Review Damage
├─ Show all deployments with damage
├─ Confirm damage status for each
└─ [Next →]

Step 2: Salvage Rolls
├─ For each destroyed unit, roll 2d6
├─ Input salvage roll results
└─ [Next →]

Step 3: Calculate Costs
├─ Auto-calculate repair costs
├─ Show reconnaissance costs
├─ Show personnel costs
├─ Total expenses
└─ [Next →]

Step 4: Select MVP
├─ Radio buttons for each pilot
├─ Shows current MVP count per pilot
└─ [Next →]

Step 5: Allocate SP to Pilots
├─ Show earned SP for each pilot (base + MVP bonus)
├─ Show upgrade limit (pilot_sp_upgrade_limit)
├─ Interactive skill upgrade selector
└─ [Next →]

Step 6: Purchase New Units (Optional)
├─ Browse available units
├─ Show warchest balance
└─ [Next →]

Step 7: Review & Finalize
├─ Summary of all changes
├─ Final warchest balance
├─ [Complete Sortie ✓]
```

### Step 3: Finalize Transaction

```elixir
def finalize_sortie(sortie, post_battle_results) do
  Repo.transaction(fn ->
    # 1. Calculate all costs
    repair_costs = calculate_repair_costs(sortie.deployments)
    personnel_costs = calculate_personnel_costs(sortie.deployments)
    total_expenses = repair_costs + personnel_costs + sortie.reconnaissance_cost_sp

    # 2. Calculate income
    total_income = (
      sortie.primary_objective_sp +
      sortie.secondary_objectives_sp +
      sortie.waypoint_income_sp -
      sortie.waypoint_costs_sp
    ) * sortie.campaign.sp_multiplier

    net_earnings = total_income - total_expenses

    # 3. Update sortie with final costs
    sortie
    |> Sortie.changeset(%{
      repair_cost_sp: repair_costs,
      personnel_cost_sp: personnel_costs,
      mvp_pilot_id: post_battle_results.mvp_pilot_id,
      is_completed: true,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()

    # 4. Update warchest
    campaign = sortie.campaign
    new_balance = campaign.warchest_balance + net_earnings

    if new_balance < 0 do
      Repo.rollback("Insufficient funds! Cannot complete sortie.")
    end

    update_campaign(campaign, %{warchest_balance: new_balance})

    # 5. Process pilot SP allocation
    for {pilot_id, sp_to_spend} <- post_battle_results.pilot_sp_allocations do
      pilot = Pilots.get_pilot!(pilot_id)

      # Validate against upgrade limit
      if sp_to_spend > sortie.pilot_sp_upgrade_limit do
        Repo.rollback("Pilot #{pilot.callsign} exceeds SP upgrade limit")
      end

      # Apply skill upgrades
      Pilots.apply_skill_upgrades(pilot, sp_to_spend, sortie)
    end

    # 6. Award MVP bonus
    if post_battle_results.mvp_pilot_id do
      mvp = Pilots.get_pilot!(post_battle_results.mvp_pilot_id)
      Pilots.award_mvp_bonus(mvp, 20)
    end

    # 7. Process unit purchases
    for unit_purchase <- post_battle_results.unit_purchases do
      Companies.purchase_unit(
        campaign.company,
        unit_purchase.master_unit,
        unit_purchase.cost_sp
      )
    end

    # 8. Update pilot/unit statuses
    for deployment <- sortie.deployments do
      case deployment.pilot_casualty do
        :wounded -> Pilots.mark_wounded(deployment.pilot)
        :killed -> Pilots.mark_killed(deployment.pilot, sortie)
        _ -> :ok
      end

      case deployment.damage_status do
        :destroyed when not deployment.was_salvaged ->
          Companies.destroy_unit(deployment.company_unit, sortie)
        _ ->
          :ok
      end
    end

    # 9. Broadcast completion
    Phoenix.PubSub.broadcast(
      Aces.PubSub,
      "campaign:#{campaign.id}",
      {:sortie_completed, sortie.id}
    )

    {:ok, sortie}
  end)
end
```

---

## SP Allocation System

### Upgrade Limit Enforcement

```elixir
def validate_pilot_sp_allocation(sortie, pilot, requested_sp) do
  cond do
    # Check against sortie limit
    sortie.pilot_sp_upgrade_limit && requested_sp > sortie.pilot_sp_upgrade_limit ->
      {:error, "Cannot exceed sortie SP limit of #{sortie.pilot_sp_upgrade_limit}"}

    # Check pilot has enough accumulated SP
    pilot_available_sp = calculate_available_sp(pilot, sortie.campaign) ->
      if requested_sp > pilot_available_sp do
        {:error, "Pilot only has #{pilot_available_sp} SP available"}
      else
        :ok
      end
  end
end

defp calculate_available_sp(pilot, campaign) do
  # SP earned in this campaign
  stats = PilotCampaignStats.get_for_pilot_and_campaign(pilot, campaign)
  stats.sp_earned - stats.sp_spent_on_skills
end
```

### Interactive SP Allocation UI

```heex
<div class="sp-allocation">
  <h3><%= @pilot.callsign %></h3>

  <div class="sp-budget">
    <p>Earned this sortie: <%= @base_sp %> SP</p>
    <%= if @pilot.id == @mvp_pilot_id do %>
      <p class="mvp-bonus">MVP Bonus: +20 SP</p>
    <% end %>
    <p>Available from previous sorties: <%= @available_sp %> SP</p>
    <p class="text-sm text-gray-500">
      Sortie upgrade limit: <%= @sortie.pilot_sp_upgrade_limit || "Unlimited" %> SP
    </p>
  </div>

  <div class="current-skills">
    <label>Current Skill: <%= @pilot.skill_level %></label>

    <!-- Skill upgrade selector -->
    <select
      name="target_skill"
      phx-change="calculate_upgrade_cost"
      phx-value-pilot-id={@pilot.id}
    >
      <%= for level <- (@pilot.skill_level - 1)..0 do %>
        <option value={level}>
          Upgrade to Skill <%= level %>
          (Cost: <%= Pilots.calculate_skill_cost(@pilot.skill_level, level) %> SP)
        </option>
      <% end %>
    </select>
  </div>

  <%= if @selected_upgrade do %>
    <div class="upgrade-preview">
      <p><strong>Upgrade:</strong> Skill <%= @pilot.skill_level %> → <%= @selected_upgrade.target_level %></p>
      <p><strong>Cost:</strong> <%= @selected_upgrade.cost %> SP</p>

      <%= if @selected_upgrade.cost > @sortie.pilot_sp_upgrade_limit do %>
        <p class="text-red-500">
          ⚠️ Exceeds sortie limit! Max <%= @sortie.pilot_sp_upgrade_limit %> SP
        </p>
      <% else %>
        <button phx-click="apply_upgrade" phx-value-pilot-id={@pilot.id}>
          Apply Upgrade ✓
        </button>
      <% end %>
    </div>
  <% end %>
</div>
```

---

## Data Locking After Completion

### Prevent Edits to Completed Sorties

```elixir
# In LiveView mount
def mount(%{"id" => sortie_id}, _session, socket) do
  sortie = Campaigns.get_sortie!(sortie_id)

  if sortie.is_completed do
    {:ok,
      socket
      |> assign(sortie: sortie, read_only: true)
      |> put_flash(:info, "This sortie is completed and cannot be edited")}
  else
    {:ok, assign(sortie: sortie, read_only: false)}
  end
end

# In update_deployment
def update_deployment(deployment, attrs) do
  sortie = deployment.sortie

  if sortie.is_completed do
    {:error, :sortie_completed}
  else
    deployment
    |> Deployment.changeset(attrs)
    |> Repo.update()
  end
end
```

### Admin Override (if needed)

```elixir
# For corrections after completion
def reopen_sortie(sortie, admin_user) do
  if admin_user.role == :admin do
    sortie
    |> Sortie.changeset(%{
      is_completed: false,
      completed_at: nil
    })
    |> Repo.update()
  else
    {:error, :unauthorized}
  end
end
```

---

## Summary

### Key Features

✅ **Real-time damage tracking** - Update deployments during play
✅ **Multi-session support** - Save progress, resume later
✅ **SP upgrade limits** - Enforce per-sortie spending caps
✅ **Comprehensive post-battle** - Multi-step wizard for all actions
✅ **Transaction safety** - All-or-nothing finalization
✅ **Data locking** - Completed sorties become read-only
✅ **Collaborative** - Multiple players see updates via PubSub

### Database Fields Summary

**Sorties:**
- `pilot_sp_upgrade_limit` - Max SP per pilot for upgrades (NEW!)
- `is_completed` - Boolean flag for state
- `completed_at` - Timestamp when finalized

**Deployments:**
- `damage_status` - Updateable during play ✅
- `pilot_casualty` - Updateable during play ✅
- `salvage_roll` - Set at completion only ✅
- `repair_cost_sp` - Calculated at completion ✅

**Workflow:**
```
Create Sortie → Deploy Units → Play Game (update damage) → Complete & Finalize
     ↓              ↓                 ↓                           ↓
is_completed:   is_completed:    is_completed:              is_completed:
  false           false            false                       true
  editable ✅     editable ✅       editable ✅                 locked 🔒
```

This gives you full flexibility to track games as they happen while ensuring data integrity through the final completion step!
