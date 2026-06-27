defmodule Mix.Tasks.SeedDev do
  @shortdoc "Seeds a demo admin user, company, 400 PV force, pilots, and a campaign"

  @moduledoc """
  Seeds a ready-to-play development scaffold:

    * a fixed, confirmed admin user (`#{"admin@aces.test"}`)
    * a mercenary company owned by that user
    * a ~400 PV force (BattleMechs, Combat Vehicles, Battle Armor, Infantry)
    * a pilot for every non-infantry unit, assigned to its unit
    * a finalized (active) company with a started campaign

  ## Usage

      mix seed_dev

  The task is idempotent: if the admin user already exists it reports and exits
  without making changes.

  ## Prerequisites

  BattleMech and Combat Vehicle master units must already be cached (run
  `mix seed_master_units` first). The Battle Armor and Conventional Infantry used
  by the force are baked into this task as real MUL data and upserted offline, so
  they need no separate seeding.
  """

  use Mix.Task

  import Ecto.Query, warn: false

  alias Aces.Accounts
  alias Aces.Accounts.User
  alias Aces.Campaigns
  alias Aces.Companies
  alias Aces.Companies.Pilots
  alias Aces.Companies.Units, as: Roster
  alias Aces.Repo
  alias Aces.Units
  alias Aces.Units.MasterUnit

  @admin_email "admin@aces.test"
  @admin_password "password1234"

  @company_name "Crimson Lances"
  @company_description "A scrappy mercenary outfit cutting its teeth on the Periphery frontier."

  @campaign_name "Operation First Blood"
  @campaign_description "The company's opening contract: secure a contested mining world."

  # Force composition (total 8 units, ~400 PV). Non-infantry units each get a
  # pilot, so the non-infantry count must stay within the 6-pilot draft cap.
  @force_plan [
    {"conventional_infantry", 2},
    {"battle_armor", 1},
    {"combat_vehicle", 2},
    {"battlemech", 3}
  ]

  @pv_budget 400

  # Canonical Battle Armor and Conventional Infantry units, captured from the MUL.
  #
  # On the MUL both share the "Infantry" unit type (Type.Id 21); only the BFType
  # sub-type ("BA" vs "CI") distinguishes them. The seed_master_units type filter
  # can't separate them (and resolves them all to battle_armor), so we bake a
  # curated, real selection of each in here with the correct unit_type. These are
  # upserted by mul_id, so they also correct any record previously mis-typed.
  @canonical_units [
    %{
      mul_id: 4215,
      name: "Gladiator Battle Armor S (Sqd4)",
      variant: "S (Sqd4)",
      full_name: "Gladiator Battle Armor S (Sqd4)",
      unit_type: "battle_armor",
      tonnage: 0,
      point_value: 7,
      battle_value: 47,
      technology_base: "Inner Sphere",
      rules_level: "Advanced",
      role: "Scout",
      bf_move: "8\"f",
      bf_size: 1,
      bf_armor: 0,
      bf_structure: 2,
      bf_damage_short: "1",
      bf_damage_medium: "0",
      bf_damage_long: "0",
      bf_overheat: 0,
      bf_abilities: "AM,CAR4,XMEC",
      image_url: "https://i.ibb.co/qxsfX2D/gladiator-s-proto.png",
      era_id: 15,
      date_introduced: 3084,
      is_published: true
    },
    %{
      mul_id: 1615,
      name: "Infiltrator Mk. I Battle Armor (Special Ops) (Sqd4)",
      variant: "(Special Ops) (Sqd4)",
      full_name: "Infiltrator Mk. I Battle Armor (Special Ops) (Sqd4)",
      unit_type: "battle_armor",
      tonnage: 1,
      point_value: 10,
      battle_value: 98,
      technology_base: "Inner Sphere",
      rules_level: "Standard",
      role: "Ambusher",
      bf_move: "4\"f",
      bf_size: 1,
      bf_armor: 1,
      bf_structure: 2,
      bf_damage_short: "0",
      bf_damage_medium: "0",
      bf_damage_long: "0",
      bf_overheat: 0,
      bf_abilities: "CAR4,MEC,RCN,RSD1,STL",
      image_url: "https://i.ibb.co/5Ls7Ym6/infiltrator-mk-i-3058u.png",
      era_id: 247,
      date_introduced: 3062,
      is_published: true
    },
    %{
      mul_id: 1279,
      name: "Gray Death Standard Suit [MG] (Sqd4)",
      variant: "[MG] (Sqd4)",
      full_name: "Gray Death Standard Suit [MG] (Sqd4)",
      unit_type: "battle_armor",
      tonnage: 1,
      point_value: 11,
      battle_value: 193,
      technology_base: "Inner Sphere",
      rules_level: "Standard",
      role: "Ambusher",
      bf_move: "6\"f",
      bf_size: 1,
      bf_armor: 1,
      bf_structure: 2,
      bf_damage_short: "1",
      bf_damage_medium: "0",
      bf_damage_long: "0",
      bf_overheat: 0,
      bf_abilities: "AM,CAR4,MEC,RCN",
      image_url: "https://i.ibb.co/7NLj0Yk/gray-death-standard-3058u.png",
      era_id: 13,
      date_introduced: 3052,
      is_published: true
    },
    %{
      mul_id: 2141,
      name: "Mechanized Tracked Platoon (MG)",
      variant: "(MG)",
      full_name: "Mechanized Tracked Platoon (MG)",
      unit_type: "conventional_infantry",
      tonnage: 28,
      point_value: 5,
      battle_value: 75,
      technology_base: "Inner Sphere",
      rules_level: "Standard",
      role: "Ambusher",
      bf_move: "6\"t",
      bf_size: 1,
      bf_armor: 1,
      bf_structure: 1,
      bf_damage_short: "1",
      bf_damage_medium: "0",
      bf_damage_long: "0",
      bf_overheat: 0,
      bf_abilities: "CAR28",
      image_url: "https://i.ibb.co/5TGJ8px/mul-blank.png",
      era_id: 9,
      date_introduced: nil,
      is_published: true
    },
    %{
      mul_id: 2148,
      name: "Mechanized Wheeled Platoon (Rifle, Ballistic)",
      variant: "(Rifle, Ballistic)",
      full_name: "Mechanized Wheeled Platoon (Rifle, Ballistic)",
      unit_type: "conventional_infantry",
      tonnage: 24,
      point_value: 5,
      battle_value: 59,
      technology_base: "Inner Sphere",
      rules_level: "Standard",
      role: "Ambusher",
      bf_move: "8\"w",
      bf_size: 1,
      bf_armor: 1,
      bf_structure: 1,
      bf_damage_short: "1",
      bf_damage_medium: "0",
      bf_damage_long: "0",
      bf_overheat: 0,
      bf_abilities: "CAR24",
      image_url: "https://i.ibb.co/5TGJ8px/mul-blank.png",
      era_id: 9,
      date_introduced: nil,
      is_published: true
    },
    %{
      mul_id: 1143,
      name: "Foot Platoon (Flamer)",
      variant: "(Flamer)",
      full_name: "Foot Platoon (Flamer)",
      unit_type: "conventional_infantry",
      tonnage: 3,
      point_value: 8,
      battle_value: 74,
      technology_base: "Inner Sphere",
      rules_level: "Introductory",
      role: "Ambusher",
      bf_move: "2\"f",
      bf_size: 1,
      bf_armor: 2,
      bf_structure: 1,
      bf_damage_short: "1",
      bf_damage_medium: "0",
      bf_damage_long: "0",
      bf_overheat: 0,
      bf_abilities: "AM,CAR3,HT1/-/-",
      image_url: "https://i.ibb.co/5TGJ8px/mul-blank.png",
      era_id: 9,
      date_introduced: 2025,
      is_published: true
    }
  ]

  @canonical_mul_ids Enum.map(@canonical_units, & &1.mul_id)

  # Roster of pilots, one per non-infantry unit, matched by unit_type.
  @pilot_roster [
    %{name: "Marcus Kane", callsign: "Reaper", unit_type: "battlemech"},
    %{name: "Yuki Tanaka", callsign: "Frost", unit_type: "battlemech"},
    %{name: "Dimitri Volkov", callsign: "Hammer", unit_type: "battlemech"},
    %{name: "Elena Ruiz", callsign: "Viper", unit_type: "combat_vehicle"},
    %{name: "Samuel Okoro", callsign: "Bulldog", unit_type: "combat_vehicle"},
    %{name: "Priya Nair", callsign: "Shadow", unit_type: "battle_armor"}
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    cond do
      Accounts.get_user_by_email(@admin_email) ->
        info("ℹ️  Admin user #{@admin_email} already exists — nothing to do.")
        info("    Delete it (and its company) first if you want to re-seed.")

      Units.count_cached_units() == 0 ->
        error("❌ No master units cached. Run `mix seed_master_units` first.")
        System.halt(1)

      true ->
        seed()
    end
  end

  defp seed do
    ensure_canonical_units()

    user = create_admin()
    info("👤 Created admin user: #{user.email}")

    {:ok, company} =
      Companies.create_company(%{name: @company_name, description: @company_description}, user)

    info("🏢 Created company: #{company.name} (PV budget #{company.pv_budget})")

    added = build_force(company)
    spent = Enum.sum(Enum.map(added, & &1.master_unit.point_value))
    info("🤖 Added #{length(added)} units totaling #{spent} PV:")

    Enum.each(added, fn cu ->
      info(
        "    • #{MasterUnit.display_name(cu.master_unit)} " <>
          "(#{cu.master_unit.unit_type}, #{cu.master_unit.point_value} PV)"
      )
    end)

    pilots = create_pilots(company)
    info("🎖️  Created #{length(pilots)} pilots")

    assigned = assign_pilots(company, pilots)
    info("🔗 Assigned #{assigned} pilots to units")

    finalizable = Companies.get_company!(company.id)

    case Companies.finalize_company(finalizable) do
      {:ok, active} ->
        info("✅ Finalized company — now active with #{active.warchest_balance} SP warchest")
        start_campaign(active, user)

      {:error, changeset} ->
        error("❌ Could not finalize company: #{inspect(changeset.errors)}")
        System.halt(1)
    end

    info("")
    info("🎉 Seed complete! Log in with:")
    info("    email:    #{@admin_email}")
    info("    password: #{@admin_password}")
  end

  defp start_campaign(company, user) do
    attrs = %{
      "name" => @campaign_name,
      "description" => @campaign_description,
      "difficulty_level" => "standard"
    }

    case Campaigns.create_campaign(company, attrs, user: user) do
      {:ok, campaign} ->
        info("🚀 Started campaign: #{campaign.name} (#{campaign.difficulty_level})")

      {:error, changeset} ->
        error("❌ Could not start campaign: #{inspect(changeset.errors)}")
        System.halt(1)
    end
  end

  ## Admin user

  defp create_admin do
    {:ok, user} = Accounts.register_user(%{email: @admin_email, password: @admin_password})

    user
    |> User.confirm_changeset()
    |> Repo.update!()
  end

  ## Force selection

  # Builds the force by walking the planned slots cheapest-type first so that the
  # expensive BattleMech slots absorb the remaining budget toward ~400 PV. Each
  # pick is a distinct unit (distinct chassis for mechs) to satisfy the roster
  # composition rules, and the PV ceiling is ultimately enforced by the changeset.
  defp build_force(company) do
    slots = Enum.flat_map(@force_plan, fn {type, n} -> List.duplicate(type, n) end)
    total = length(slots)

    {added, _state} =
      slots
      |> Enum.with_index()
      |> Enum.reduce({[], %{spent: 0, used_ids: MapSet.new(), used_chassis: MapSet.new()}}, fn
        {type, index}, {added, state} ->
          remaining_slots = total - index
          remaining_budget = @pv_budget - state.spent
          target = max(div(remaining_budget, remaining_slots), 1)

          candidates = candidate_units(type, remaining_budget, state)

          case try_add(company, candidates, target) do
            {:ok, company_unit} ->
              mu = company_unit.master_unit

              new_state = %{
                spent: state.spent + mu.point_value,
                used_ids: MapSet.put(state.used_ids, mu.id),
                used_chassis: MapSet.put(state.used_chassis, chassis(mu))
              }

              {[company_unit | added], new_state}

            :error ->
              warn(
                "⚠️  No #{type} unit fit the remaining #{remaining_budget} PV budget — skipping slot."
              )

              {added, state}
          end
      end)

    Enum.reverse(added)
  end

  # Returns candidate master units for a slot that fit the remaining budget and
  # exclude already-used units (and, for mechs, already-used chassis). Battle Armor
  # and Conventional Infantry are restricted to the baked-in canonical set so the
  # force uses them deterministically regardless of other cached units of that type.
  # Target-based preference ordering is applied later in try_add/order_by_target.
  defp candidate_units(type, remaining_budget, state) do
    base =
      from(m in MasterUnit,
        where: m.unit_type == ^type and m.point_value > 0 and m.point_value <= ^remaining_budget,
        order_by: [asc: m.point_value, asc: m.mul_id]
      )

    query =
      if type in ["battle_armor", "conventional_infantry"] do
        from(m in base, where: m.mul_id in ^@canonical_mul_ids)
      else
        base
      end

    query
    |> Repo.all()
    |> Enum.reject(fn mu ->
      MapSet.member?(state.used_ids, mu.id) or
        (type == "battlemech" and MapSet.member?(state.used_chassis, chassis(mu)))
    end)
  end

  # Attempts to add the best-fitting candidate, falling back through the list if a
  # changeset rejects one (e.g. a composition rule we didn't pre-filter).
  defp try_add(company, candidates, target) do
    ordered = order_by_target(candidates, target)

    Enum.reduce_while(ordered, :error, fn mu, _acc ->
      case Roster.add_unit_to_company(company, mu.mul_id) do
        {:ok, company_unit} ->
          {:halt, {:ok, Repo.preload(company_unit, :master_unit)}}

        {:error, _changeset} ->
          {:cont, :error}
      end
    end)
  end

  # Prefer the priciest unit at or below target (fills budget), then cheapest above.
  defp order_by_target(candidates, target) do
    {at_or_below, above} = Enum.split_with(candidates, &(&1.point_value <= target))

    Enum.sort_by(at_or_below, & &1.point_value, :desc) ++
      Enum.sort_by(above, & &1.point_value, :asc)
  end

  # Strips the variant suffix from a unit name to derive its chassis, mirroring
  # Aces.Companies.CompanyUnit's logic.
  defp chassis(%MasterUnit{name: name, variant: variant})
       when is_binary(name) and is_binary(variant) do
    name |> String.trim_trailing(" " <> variant) |> String.trim()
  end

  defp chassis(%MasterUnit{name: name}), do: name

  ## Pilots

  defp create_pilots(company) do
    # company is freshly loaded with pilots: [], satisfying the draft pilot-limit check.
    Enum.map(@pilot_roster, fn attrs ->
      {:ok, pilot} = Pilots.create_pilot(company, attrs)
      pilot
    end)
  end

  # Assigns each pilot to an unassigned unit of a matching type.
  defp assign_pilots(company, pilots) do
    company = Companies.get_company!(company.id)
    pilots_by_type = Enum.group_by(pilots, & &1.unit_type)

    {count, _remaining} =
      Enum.reduce(company.company_units, {0, pilots_by_type}, fn cu, {count, by_type} ->
        type = cu.master_unit.unit_type

        case by_type[type] do
          [pilot | rest] ->
            {:ok, _} = Roster.update_company_unit(cu, %{pilot_id: pilot.id})
            {count + 1, Map.put(by_type, type, rest)}

          _ ->
            {count, by_type}
        end
      end)

    count
  end

  ## Canonical Battle Armor / Conventional Infantry

  # Upserts the baked-in canonical BA and CI units (real MUL data). Idempotent and
  # offline; upserting by mul_id also corrects the unit_type of any record that was
  # previously mis-classified by the type-filter seeding path.
  defp ensure_canonical_units do
    {ba, ci} = Enum.split_with(@canonical_units, &(&1.unit_type == "battle_armor"))

    Enum.each(@canonical_units, fn attrs ->
      case Units.create_or_update_master_unit(attrs) do
        {:ok, _} -> :ok
        {:error, cs} -> warn("⚠️  Could not seed #{attrs.name}: #{inspect(cs.errors)}")
      end
    end)

    info(
      "👣 Ensured #{length(ba)} canonical Battle Armor and #{length(ci)} Conventional Infantry units"
    )
  end

  ## Output helpers

  defp info(msg), do: Mix.shell().info(msg)
  defp warn(msg), do: Mix.shell().info([:yellow, msg, :reset])
  defp error(msg), do: Mix.shell().error(msg)
end
