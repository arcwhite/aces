# Timestamps & Fictional Timeline - Quick Reference

## Timestamp Handling - Summary

### ✅ You Were Right!

**Phoenix convention:** `inserted_at` and `updated_at` ✅
**UTC storage:** Using `:utc_datetime` type ✅
**Timezone handling:** Convert on display only ✅

### The Setup

```elixir
# In Ecto Schema (lib/aces/campaigns/sortie.ex)
schema "sorties" do
  field :mission_name, :string
  field :fictional_date, :date        # In-universe date (e.g., 3145-08-20)
  field :date_played, :date           # Real-world date played

  timestamps(type: :utc_datetime)     # Creates inserted_at, updated_at (UTC)
end
```

```elixir
# In Migration (priv/repo/migrations/xxx_create_sorties.exs)
def change do
  create table(:sorties) do
    add :mission_name, :string
    add :fictional_date, :date
    add :date_played, :date

    timestamps(type: :utc_datetime)   # PostgreSQL: timestamptz columns
  end
end
```

### How It Works

```
User Action                Database Storage        Display to User
─────────────────────────  ──────────────────────  ───────────────────────
Create sortie (2026-01-03  →  2026-01-03 22:30 UTC  →  "Jan 3, 2026 5:30 PM EST"
  5:30 PM EST)                 (timestamptz)           (user's timezone)

Elixir code:
DateTime.utc_now()         →  Stored as UTC         →  Calendar.strftime(...,
                                                         time_zone: "America/New_York")
```

**Key Point:** Business logic ALWAYS uses UTC. Timezone conversion happens ONLY in the view layer.

---

## Fictional Timeline - Implementation

### Schema Changes Made

#### `companies` table
```elixir
field :founding_year, :integer  # e.g., 3145
```

#### `campaigns` table
```elixir
field :fictional_start_date, :date  # e.g., ~D[3145-08-15]
field :started_at, :date            # Real-world: ~D[2026-01-03]
```

#### `sorties` table
```elixir
field :fictional_date, :date  # e.g., ~D[3145-09-03]
field :date_played, :date     # Real-world: ~D[2026-01-12]
```

### BattleTech Calendar

**Uses standard Gregorian calendar** - just in the future!

```elixir
# Valid fictional dates
~D[3145-08-15]  # August 15, 3145 ✅
~D[3152-12-31]  # December 31, 3152 ✅
~D[2784-03-20]  # March 20, 2784 (First Succession War era) ✅
```

### Example: Campaign Timeline

```elixir
company = %Company{
  name: "Gray Death Legion",
  founding_year: 3145
}

campaign = %Campaign{
  name: "Operation Serpent",
  fictional_start_date: ~D[3145-08-15],  # In-universe: August 15, 3145
  started_at: ~D[2026-01-03]              # Real-world: January 3, 2026
}

sorties = [
  %Sortie{
    mission_number: 1,
    mission_name: "Recon Raid",
    fictional_date: ~D[3145-08-20],  # 5 days after campaign start
    date_played: ~D[2026-01-05]      # 2 days after real-world start
  },
  %Sortie{
    mission_number: 2,
    mission_name: "Convoy Escort",
    fictional_date: ~D[3145-09-03],  # 14 days since last mission
    date_played: ~D[2026-01-12]      # 7 days since last session
  }
]
```

### Display in LiveView

```heex
<!-- Campaign Timeline -->
<div class="timeline">
  <h2>Operation Serpent</h2>
  <p class="text-sm text-gray-500">
    Started: <%= Calendar.strftime(@campaign.fictional_start_date, "%B %d, %Y") %>
    <span class="text-xs">(played on <%= @campaign.started_at %>)</span>
  </p>

  <%= for sortie <- @sorties do %>
    <div class="timeline-item">
      <strong>Sortie <%= sortie.mission_number %>:</strong> <%= sortie.mission_name %>
      <br>
      <span class="fictional-date">
        <%= Calendar.strftime(sortie.fictional_date, "%B %d, %Y") %>
      </span>
      <span class="real-date text-xs text-gray-500">
        (played <%= Calendar.strftime(sortie.date_played, "%b %d") %>)
      </span>

      <%= if sortie != hd(@sorties) do %>
        <span class="text-xs">
          <%= days_since_last_mission(sortie) %> days since last mission
        </span>
      <% end %>
    </div>
  <% end %>
</div>
```

**Renders as:**
```
Operation Serpent
Started: August 15, 3145 (played on 2026-01-03)

Sortie 1: Recon Raid
  August 20, 3145 (played Jan 5)

Sortie 2: Convoy Escort
  September 3, 3145 (played Jan 12)
  14 days since last mission

Sortie 3: Assault
  September 10, 3145 (played Jan 19)
  7 days since last mission
```

---

## Helper Functions

### Calculate Time Between Missions (Fictional)

```elixir
defmodule Aces.Campaigns do
  def days_between_missions(sortie1, sortie2) do
    case {sortie1.fictional_date, sortie2.fictional_date} do
      {%Date{} = d1, %Date{} = d2} ->
        Date.diff(d2, d1)

      _ ->
        nil  # No fictional dates set
    end
  end

  def suggest_next_fictional_date(last_sortie, campaign) do
    base = last_sortie.fictional_date || campaign.fictional_start_date

    # Suggest 7-14 days after last mission (typical downtime)
    Date.add(base, Enum.random(7..14))
  end
end
```

### In the LiveView Form

```elixir
def mount(%{"campaign_id" => campaign_id}, _session, socket) do
  campaign = Campaigns.get_campaign!(campaign_id)
  last_sortie = Campaigns.get_last_sortie(campaign)

  suggested_date = Campaigns.suggest_next_fictional_date(last_sortie, campaign)

  changeset = Campaigns.change_sortie(%Sortie{
    fictional_date: suggested_date,  # Pre-fill with suggestion
    date_played: Date.utc_today()    # Default to today
  })

  {:ok, assign(socket, campaign: campaign, changeset: changeset)}
end
```

---

## Database Constraints

### Check Constraints

```sql
-- Companies
ALTER TABLE companies
  ADD CONSTRAINT founding_year_range
  CHECK (founding_year >= 2500 AND founding_year <= 4000);

-- Campaigns
ALTER TABLE campaigns
  ADD CONSTRAINT fictional_start_date_range
  CHECK (fictional_start_date >= '2500-01-01'::date
     AND fictional_start_date <= '4000-12-31'::date);

-- Sorties
ALTER TABLE sorties
  ADD CONSTRAINT fictional_date_range
  CHECK (fictional_date >= '2500-01-01'::date
     AND fictional_date <= '4000-12-31'::date);
```

### Validation in Changesets

```elixir
def changeset(campaign, attrs) do
  campaign
  |> cast(attrs, [:name, :fictional_start_date, :started_at, ...])
  |> validate_required([:name, :started_at])
  |> validate_fictional_date_range()
end

defp validate_fictional_date_range(changeset) do
  changeset
  |> validate_change(:fictional_start_date, fn :fictional_start_date, date ->
    cond do
      is_nil(date) -> []  # Optional field
      date.year < 2500 -> [fictional_start_date: "must be year 2500 or later"]
      date.year > 4000 -> [fictional_start_date: "must be year 4000 or earlier"]
      true -> []
    end
  end)
end
```

---

## Testing Examples

```elixir
describe "fictional timeline" do
  test "calculates days between missions" do
    sortie1 = insert(:sortie, fictional_date: ~D[3145-08-20])
    sortie2 = insert(:sortie, fictional_date: ~D[3145-09-03])

    assert Campaigns.days_between_missions(sortie1, sortie2) == 14
  end

  test "suggests next fictional date 7-14 days out" do
    campaign = insert(:campaign, fictional_start_date: ~D[3145-08-01])
    last_sortie = insert(:sortie, fictional_date: ~D[3145-08-15])

    suggested = Campaigns.suggest_next_fictional_date(last_sortie, campaign)

    assert Date.diff(suggested, last_sortie.fictional_date) in 7..14
    assert suggested.year == 3145
  end

  test "validates fictional dates within reasonable range" do
    changeset = Campaign.changeset(%Campaign{}, %{
      fictional_start_date: ~D[1999-01-01]  # Too early!
    })

    assert "must be year 2500 or later" in errors_on(changeset).fictional_start_date
  end
end
```

---

## Summary

### ✅ Answers to Your Questions

1. **`inserted_at` naming?**
   → Yes! Phoenix standard. Using `timestamps(type: :utc_datetime)` ✅

2. **UTC timestamps?**
   → Already configured! `:utc_datetime` = UTC storage, timezone conversion only on display ✅

3. **Fictional timeline?**
   → Added! `founding_year`, `fictional_start_date`, `fictional_date` fields ✅

### Key Principles

- **All timestamps in UTC** - business logic never deals with timezones
- **Fictional dates are just far-future dates** - use standard Elixir `Date` type
- **Two parallel timelines** - real-world (when played) + fictional (in-universe)
- **Convert on display only** - use `Calendar.strftime/3` with `:time_zone` option

This gives players both the narrative timeline they care about AND tracks their real-world play history!
