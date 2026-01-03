# Master Unit List Integration Strategy

## Overview

Integration with the Master Unit List (MUL) for unit data, balancing offline capability with up-to-date information.

---

## MUL API Research Summary

### API Endpoints (Unofficial/Reverse-Engineered)

**Base URL:** `https://masterunitlist.azurewebsites.net`

**Primary Endpoint:** `/Unit/QuickList`

**Parameters:**
- `Name` - Unit name search (e.g., "Atlas", "WHM-7A")
- `MinTons` / `MaxTons` - Weight range filter
- `Types` - Unit type ID (18 = BattleMech, 19 = Combat Vehicle, etc.)
- `Factions` - Faction availability ID
- `AvailableEras` - Era ID (14 = ilClan)

**Response Format:** JSON

```json
{
  "Units": [
    {
      "Id": 39,
      "Name": "Atlas",
      "Variant": "AS7-D",
      "Class": "Assault",
      "Tonnage": 100,
      "BattleValue": 1897,
      "Technology": "Inner Sphere",
      "Rules": "Standard",
      "Cost": 9626000,
      "DateIntroduced": 2755,
      "EraId": 2,
      "Type": "BattleMech",
      "Role": "Juggernaut",
      "BFPointValue": 48,
      "BFArmor": 8,
      "BFStructure": 4,
      "BFMove": "4\"",
      "BFDamageShort": "4",
      "BFDamageMedium": "4",
      "BFDamageLong": "2",
      "BFOverheat": 0,
      "BFAbilities": "AC2/2/2, LRM1/1/1, SRM2/2/0",
      "ImageUrl": "/Unit/QuickImage/39",
      "IsPublished": true,
      "IsFeatured": false,
      "Release": null
    }
  ],
  "Search": {...},
  "Crumbs": [...]
}
```

### Key Findings

**Pros:**
- ✅ Returns complete Alpha Strike data (BFPointValue, armor, structure, damage)
- ✅ JSON format (easy to parse)
- ✅ Comprehensive filtering
- ✅ Includes images
- ✅ Up-to-date with latest releases

**Cons:**
- ❌ **Unofficial API** - no documentation, no SLA
- ❌ **No rate limiting info** - risk of being blocked
- ❌ **Could break** - endpoint format could change
- ❌ **No offline** - requires internet connection
- ❌ **Slow initial load** - thousands of units

---

## Hybrid Integration Strategy

### Architecture: Three-Tiered Approach

```
┌─────────────────────────────────────────────┐
│ User Interface (LiveView)                   │
│ "I want to add a Timber Wolf to my roster" │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│ Aces.Units Context                          │
│ 1. Check local database first               │
│ 2. If not found, query MUL API              │
│ 3. Cache API response in database           │
└──────────────────┬──────────────────────────┘
                   │
        ┌──────────┴──────────┐
        ▼                     ▼
┌──────────────┐    ┌──────────────────┐
│ PostgreSQL   │    │ MUL API          │
│ master_units │    │ (external)       │
│ (cached)     │    │                  │
└──────────────┘    └──────────────────┘
```

### Implementation Phases

#### Phase 1: Seed Core Units (Initial Setup)

**Goal:** Populate database with commonly-used units for offline capability

**What to seed:**
- IlClan era units (Era ID 14+)
- Mercenaries faction availability
- All BattleMechs < 100 tons
- Common vehicles, BA, infantry

**Estimated size:**
- ~500-1000 units
- ~2-5 MB in database

**Implementation:**
```bash
mix seed_master_units --era ilclan --faction mercenaries
```

**Mix Task: `lib/mix/tasks/seed_master_units.ex`**

```elixir
defmodule Mix.Tasks.SeedMasterUnits do
  use Mix.Task
  alias Aces.MUL.Client
  alias Aces.Units

  @shortdoc "Seeds master units from MUL API"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [era: :string, faction: :string, all: :boolean],
      aliases: [e: :era, f: :faction, a: :all]
    )

    IO.puts("Fetching units from Master Unit List...")

    filters = build_filters(opts)
    units = Client.fetch_units(filters)

    IO.puts("Found #{length(units)} units")
    IO.puts("Importing to database...")

    Enum.each(units, fn unit_data ->
      case Units.create_or_update_master_unit(unit_data) do
        {:ok, _unit} -> IO.write(".")
        {:error, _} -> IO.write("x")
      end
    end)

    IO.puts("\nDone!")
  end

  defp build_filters(opts) do
    %{}
    |> maybe_add_era(opts[:era])
    |> maybe_add_faction(opts[:faction])
  end
end
```

#### Phase 2: API Client Module

**Module: `lib/aces/mul/client.ex`**

```elixir
defmodule Aces.MUL.Client do
  @moduledoc """
  Client for Master Unit List API
  """

  @base_url "https://masterunitlist.azurewebsites.net"

  @doc """
  Fetches units from MUL API with filters

  ## Examples

      iex> Client.fetch_units(%{era: "ilclan", types: [18]})
      {:ok, [%{...}, ...]}
  """
  def fetch_units(filters \\ %{}) do
    query_string = build_query_string(filters)
    url = "#{@base_url}/Unit/QuickList#{query_string}"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} ->
        units = parse_response(body)
        {:ok, units}

      {:ok, %{status: status}} ->
        {:error, "MUL API returned status #{status}"}

      {:error, reason} ->
        {:error, "Failed to connect to MUL API: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetches a single unit by MUL ID
  """
  def fetch_unit(mul_id) do
    url = "#{@base_url}/Unit/Details/#{mul_id}"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_unit_details(body)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches unit image
  """
  def fetch_unit_image(mul_id) do
    "#{@base_url}/Unit/QuickImage/#{mul_id}"
  end

  # Private helpers

  defp build_query_string(filters) when filters == %{}, do: ""
  defp build_query_string(filters) do
    params =
      filters
      |> Enum.map(fn {key, value} -> encode_param(key, value) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("&")

    "?" <> params
  end

  defp encode_param(:era, "ilclan"), do: "AvailableEras=14"
  defp encode_param(:types, types) when is_list(types) do
    Enum.map_join(types, "&", fn t -> "Types=#{t}" end)
  end
  defp encode_param(:min_tons, tons), do: "MinTons=#{tons}"
  defp encode_param(:max_tons, tons), do: "MaxTons=#{tons}"
  defp encode_param(:name, name), do: "Name=#{URI.encode(name)}"
  defp encode_param(_, _), do: nil

  defp parse_response(%{"Units" => units}) when is_list(units) do
    Enum.map(units, &normalize_unit/1)
  end
  defp parse_response(_), do: []

  defp normalize_unit(api_data) do
    %{
      mul_id: api_data["Id"],
      name: api_data["Name"],
      variant: api_data["Variant"],
      full_name: "#{api_data["Name"]} #{api_data["Variant"]}",
      unit_type: map_unit_type(api_data["Type"]),
      tonnage: api_data["Tonnage"],
      point_value: api_data["BFPointValue"],
      battle_value: api_data["BattleValue"],
      technology_base: api_data["Technology"],
      rules_level: api_data["Rules"],
      role: api_data["Role"],
      cost: api_data["Cost"],
      date_introduced: api_data["DateIntroduced"],
      era_id: api_data["EraId"],
      bf_move: api_data["BFMove"],
      bf_armor: api_data["BFArmor"],
      bf_structure: api_data["BFStructure"],
      bf_damage_short: api_data["BFDamageShort"],
      bf_damage_medium: api_data["BFDamageMedium"],
      bf_damage_long: api_data["BFDamageLong"],
      bf_overheat: api_data["BFOverheat"],
      bf_abilities: api_data["BFAbilities"],
      image_url: api_data["ImageUrl"],
      is_published: api_data["IsPublished"],
      last_synced_at: DateTime.utc_now()
    }
  end

  defp map_unit_type("BattleMech"), do: :battlemech
  defp map_unit_type("Combat Vehicle"), do: :combat_vehicle
  defp map_unit_type("Battle Armor"), do: :battle_armor
  defp map_unit_type("Infantry"), do: :conventional_infantry
  defp map_unit_type("ProtoMech"), do: :protomech
  defp map_unit_type(_), do: :other
end
```

#### Phase 3: Smart Caching in Units Context

**Module: `lib/aces/units.ex`**

```elixir
defmodule Aces.Units do
  @moduledoc """
  Context for managing unit data (master units and company units)
  """

  import Ecto.Query
  alias Aces.Repo
  alias Aces.Units.MasterUnit
  alias Aces.MUL.Client

  @cache_ttl_days 30  # Refresh cached units after 30 days

  @doc """
  Search for units - checks local DB first, falls back to API

  ## Examples

      iex> search_units("Atlas")
      [%MasterUnit{name: "Atlas", variant: "AS7-D"}, ...]
  """
  def search_units(search_term, opts \\ []) do
    local_results = search_local_units(search_term, opts)

    # If we have recent local results, return them
    if length(local_results) > 0 do
      local_results
    else
      # Try API as fallback
      case search_and_cache_from_api(search_term, opts) do
        {:ok, units} -> units
        {:error, _reason} -> []  # Graceful degradation
      end
    end
  end

  @doc """
  Get unit by MUL ID - checks cache first, then API
  """
  def get_master_unit_by_mul_id(mul_id) do
    case Repo.get_by(MasterUnit, mul_id: mul_id) do
      nil ->
        # Not in cache, fetch from API
        fetch_and_cache_unit(mul_id)

      unit ->
        # Check if cache is stale
        if cache_stale?(unit) do
          refresh_unit_from_api(unit)
        else
          {:ok, unit}
        end
    end
  end

  # Private functions

  defp search_local_units(search_term, opts) do
    MasterUnit
    |> where([u], ilike(u.name, ^"%#{search_term}%") or
                   ilike(u.variant, ^"%#{search_term}%"))
    |> apply_filters(opts)
    |> order_by([u], u.name)
    |> limit(50)
    |> Repo.all()
  end

  defp search_and_cache_from_api(search_term, opts) do
    filters = %{name: search_term}
              |> Map.merge(Enum.into(opts, %{}))

    case Client.fetch_units(filters) do
      {:ok, api_units} ->
        cached_units = Enum.map(api_units, &create_or_update_master_unit/1)
        {:ok, Enum.map(cached_units, fn {:ok, u} -> u end)}

      error -> error
    end
  end

  defp fetch_and_cache_unit(mul_id) do
    case Client.fetch_unit(mul_id) do
      {:ok, unit_data} ->
        create_or_update_master_unit(unit_data)

      error -> error
    end
  end

  defp cache_stale?(unit) do
    if unit.last_synced_at do
      days_since_sync = DateTime.diff(DateTime.utc_now(), unit.last_synced_at, :day)
      days_since_sync > @cache_ttl_days
    else
      true
    end
  end

  defp refresh_unit_from_api(unit) do
    case Client.fetch_unit(unit.mul_id) do
      {:ok, fresh_data} ->
        unit
        |> MasterUnit.changeset(fresh_data)
        |> Repo.update()

      {:error, _} ->
        # API failed, return stale data
        {:ok, unit}
    end
  end

  def create_or_update_master_unit(attrs) do
    case Repo.get_by(MasterUnit, mul_id: attrs.mul_id) do
      nil ->
        %MasterUnit{}
        |> MasterUnit.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> MasterUnit.changeset(attrs)
        |> Repo.update()
    end
  end

  defp apply_filters(query, []), do: query
  defp apply_filters(query, [{:unit_type, type} | rest]) do
    query
    |> where([u], u.unit_type == ^type)
    |> apply_filters(rest)
  end
  defp apply_filters(query, [{:min_pv, min} | rest]) do
    query
    |> where([u], u.point_value >= ^min)
    |> apply_filters(rest)
  end
  defp apply_filters(query, [{:max_pv, max} | rest]) do
    query
    |> where([u], u.point_value <= ^max)
    |> apply_filters(rest)
  end
  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)
end
```

---

## Type IDs Reference

### Unit Types

| ID | Type | Use in Aces? |
|----|------|--------------|
| 18 | BattleMech | ✅ Yes |
| 19 | Combat Vehicle | ✅ Yes |
| 21 | Battle Armor | ✅ Yes |
| 22 | Infantry | ✅ Yes |
| 20 | ProtoMech | ⚠️ Maybe |
| 23 | Support Vehicle | ⚠️ Maybe |

### Era IDs

| ID | Era | Focus? |
|----|-----|--------|
| 2 | Star League | ❌ No |
| 3 | Succession Wars | ❌ No |
| 4 | Clan Invasion | ⚠️ Optional |
| 11 | Republic | ⚠️ Optional |
| 13 | Dark Age | ⚠️ Optional |
| **14** | **ilClan** | **✅ Primary** |

---

## Error Handling Strategy

### Graceful Degradation

```elixir
def search_units_with_fallback(search_term) do
  case search_local_units(search_term) do
    [] ->
      case search_api_units(search_term) do
        {:ok, units} -> {:ok, units, source: :api}
        {:error, _} -> {:ok, [], source: :offline}
      end

    local_units ->
      {:ok, local_units, source: :cache}
  end
end
```

### User-Facing Error Messages

| Scenario | User Message |
|----------|--------------|
| Unit not in cache, API down | "This unit isn't in our database yet. Please try again when connected to the internet." |
| API slow | "Loading units from Master Unit List... (Show cached results)" |
| API rate limited | "Too many requests. Showing cached results." |
| Unit not found anywhere | "Unit not found. Try searching by chassis name (e.g., 'Atlas' instead of 'AS7-D')" |

---

## Performance Optimizations

### 1. Batch API Requests

Instead of fetching one unit at a time, batch requests:

```elixir
def seed_battlemechs_by_tonnage(min_tons, max_tons) do
  filters = %{
    types: [18],  # BattleMechs only
    min_tons: min_tons,
    max_tons: max_tons,
    era: "ilclan"
  }

  {:ok, units} = Client.fetch_units(filters)

  # Batch insert
  Repo.insert_all(MasterUnit, units, on_conflict: :replace_all)
end
```

### 2. Database Indexes

Optimize searches with proper indexes (see DATABASE_SCHEMA.md):

- GIN index on `factions` JSONB column
- B-tree indexes on `name`, `point_value`, `unit_type`
- Full-text search index on `name || ' ' || variant`

### 3. Preload Popular Units

Create a "starter pack" of units:

```sql
-- Top 100 most popular units
INSERT INTO master_units (...)
VALUES (...) -- Atlas AS7-D, Timber Wolf, etc.
ON CONFLICT (mul_id) DO NOTHING;
```

### 4. Image Caching

Store MUL images locally:

```elixir
defmodule Aces.Units.ImageCache do
  def fetch_and_cache_image(mul_id) do
    local_path = "priv/static/images/units/#{mul_id}.png"

    if File.exists?(local_path) do
      "/images/units/#{mul_id}.png"
    else
      url = Client.fetch_unit_image(mul_id)
      download_and_save(url, local_path)
      "/images/units/#{mul_id}.png"
    end
  end
end
```

---

## Sync Strategy

### Background Jobs (Optional)

Use Oban for periodic sync:

```elixir
defmodule Aces.Workers.SyncMasterUnits do
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"era" => era}}) do
    Units.sync_units_from_mul(era: era)
    :ok
  end
end

# Schedule weekly sync
%{era: "ilclan"}
|> Aces.Workers.SyncMasterUnits.new(schedule_in: {7, :days})
|> Oban.insert()
```

### Manual Refresh

Provide admin UI to trigger sync:

```heex
<button phx-click="sync_mul_units" class="btn btn-primary">
  Sync Units from MUL
</button>
```

---

## Testing Strategy

### 1. Mock API Responses

```elixir
# test/support/mul_api_mock.ex
defmodule Aces.MUL.Mock do
  def fetch_units(%{name: "Atlas"}) do
    {:ok, [
      %{
        mul_id: 39,
        name: "Atlas",
        variant: "AS7-D",
        point_value: 48,
        # ... other fields
      }
    ]}
  end

  def fetch_units(_) do
    {:error, :not_found}
  end
end
```

### 2. Integration Tests

```elixir
# test/aces/units_test.exs
test "searches local units first, falls back to API" do
  # Seed one local unit
  insert(:master_unit, name: "Atlas", variant: "AS7-D")

  # Search should return local result
  results = Units.search_units("Atlas")
  assert length(results) == 1
  assert hd(results).name == "Atlas"
end

test "caches API results" do
  # Mock API
  expect(MUL.Mock, :fetch_units, fn _ ->
    {:ok, [%{mul_id: 123, name: "Timber Wolf"}]}
  end)

  # First search hits API
  Units.search_units("Timber Wolf")

  # Second search should use cache
  results = Units.search_units("Timber Wolf")
  assert hd(results).mul_id == 123
end
```

### 3. Offline Testing

```elixir
test "works offline when units are cached" do
  # Seed local units
  insert(:master_unit, name: "Atlas")

  # Simulate API down
  expect(MUL.Mock, :fetch_units, fn _ -> {:error, :timeout} end)

  # Should still return cached results
  results = Units.search_units("Atlas")
  assert length(results) == 1
end
```

---

## Migration Path

### Phase 1 (MVP): Seed Only
- Run seed task on deployment
- No API calls during runtime
- Limited unit selection
- Fast, predictable

### Phase 2: Hybrid (Recommended)
- Seed core units (500-1000)
- API fallback for missing units
- Cache all API responses
- Best of both worlds

### Phase 3: API-First (Future)
- Minimal seeding
- Rely on API for most queries
- Aggressive caching
- Always up-to-date

---

## Recommended Approach

**Start with Phase 2 (Hybrid):**

1. ✅ Seed IlClan Mercenaries units (500-1000 units)
2. ✅ Implement API client with error handling
3. ✅ Add smart caching in Units context
4. ✅ Monitor API reliability
5. ✅ Add manual sync button for admins

**Benefits:**
- Works offline with cached units
- Access to full MUL catalog via API
- Graceful degradation if API is down
- Always improving as more units are cached

**Risks Mitigated:**
- MUL API changes → still have cached data
- API rate limits → fall back to cache
- Slow API → show cached results instantly
- Offline play → seeded units available

---

## Summary

The hybrid approach provides the best user experience:
- **Fast** - local database for common units
- **Complete** - API access to full catalog
- **Reliable** - works offline with cached data
- **Up-to-date** - syncs new units as they're released

This strategy respects the unofficial nature of the MUL API while providing a robust, production-ready solution.

**Sources:**
- [Master Unit List](https://masterunitlist.azurewebsites.net/)
- [casperionx/mul_api GitHub](https://github.com/casperionx/mul_api)
- [Jeff's BattleTech Tools IIC](https://jeffs-bt-tools.github.io/battletech-tools/)
- [MechStrategen: Jeff's BattleTech Tools IIC Review](https://mechstrategen.de/en/jeffs-battletech-tools-iic-for-alpha-strike/)
