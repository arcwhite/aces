defmodule Aces.MUL.Vocabulary do
  @moduledoc """
  Single source of truth for the era, faction, and unit-type vocabularies
  shared between `Aces.Units.Filters`, `Aces.MUL.Client`, the seed tasks, and
  the unit-search modal.

  Migrations must never consume this module — they need to freeze the schema
  vocabulary as of their timestamp rather than track a moving definition.
  """

  # Serves both era axes (see the Filters moduledoc on introduction vs
  # availability era): every entry is a valid *introduction* era for `Filters`
  # `:era`, and every entry is also offered as an *availability* era — the
  # modal's era buttons and the seed matrix's iteration set.
  #
  # All ten carry real faction-availability data on MUL, verified against the
  # live QuickList endpoint. The tail is thin — Star League returns ~48
  # mercenary-available units against ilClan's ~1300 — but thin is not empty,
  # so none are withheld from the selector.
  @eras [
    %{key: "ilclan", label: "ilClan", era_id: 257},
    %{key: "dark_age", label: "Dark Age", era_id: 16},
    %{key: "late_republic", label: "Late Republic", era_id: 254},
    %{key: "early_republic", label: "Early Republic", era_id: 15},
    %{key: "jihad", label: "Jihad", era_id: 14},
    %{key: "civil_war", label: "Civil War", era_id: 247},
    %{key: "clan_invasion", label: "Clan Invasion", era_id: 13},
    %{key: "late_succession_war", label: "Late Succession War", era_id: 256},
    %{key: "early_succession_war", label: "Early Succession War", era_id: 11},
    %{key: "star_league", label: "Star League", era_id: 10}
  ]

  # Legacy era spellings accepted by `Filters` `:era`. Kept so callers that
  # predate the canonical keys keep resolving to the same era_id.
  @era_aliases %{"republic" => "late_republic"}

  @factions [
    %{key: "mercenary", label: "Mercenary", group: :mercenary},
    %{key: "capellan_confederation", label: "Capellan Confederation", group: :inner_sphere},
    %{key: "draconis_combine", label: "Draconis Combine", group: :inner_sphere},
    %{key: "federated_suns", label: "Federated Suns", group: :inner_sphere},
    %{key: "free_worlds_league", label: "Free Worlds League", group: :inner_sphere},
    %{key: "lyran_commonwealth", label: "Lyran Commonwealth", group: :inner_sphere},
    %{key: "republic_of_the_sphere", label: "Republic of the Sphere", group: :inner_sphere},
    %{key: "clan_wolf", label: "Clan Wolf", group: :clan},
    %{key: "clan_jade_falcon", label: "Clan Jade Falcon", group: :clan},
    %{key: "clan_ghost_bear", label: "Clan Ghost Bear", group: :clan},
    %{key: "clan_sea_fox", label: "Clan Sea Fox", group: :clan},
    %{key: "clan_hell_horses", label: "Clan Hell's Horses", group: :clan}
  ]

  @unit_types [
    %{key: "battlemech", label: "BattleMech", mul_type_id: 18},
    %{key: "combat_vehicle", label: "Combat Vehicle", mul_type_id: 19},
    %{key: "battle_armor", label: "Battle Armor", mul_type_id: 21},
    %{key: "conventional_infantry", label: "Infantry", mul_type_id: 21},
    %{key: "protomech", label: "ProtoMech", mul_type_id: 20}
  ]

  # Faction option groups, in the order they should render in the modal
  # <select>. `nil` label renders as loose <option>s (no <optgroup>).
  @faction_option_groups [
    {nil, :mercenary},
    {"Inner Sphere", :inner_sphere},
    {"Clans", :clan}
  ]

  @doc "Full era vocabulary entries."
  def eras, do: @eras

  @doc "Full faction vocabulary entries."
  def factions, do: @factions

  @doc "Faction keys in canonical (render) order."
  def faction_keys, do: Enum.map(@factions, & &1.key)

  @doc "Full unit-type vocabulary entries."
  def unit_types, do: @unit_types

  @doc "Era keys in canonical order."
  def era_keys, do: Enum.map(@eras, & &1.key)

  @doc """
  Era key → MUL API era_id map, including legacy aliases so `:era` filtering
  keeps resolving spellings that predate the canonical keys.
  """
  def era_ids do
    canonical = Map.new(@eras, &{&1.key, &1.era_id})

    Enum.reduce(@era_aliases, canonical, fn {alias_key, target}, acc ->
      Map.put(acc, alias_key, Map.fetch!(canonical, target))
    end)
  end

  @doc "Unit-type keys in canonical order."
  def unit_type_keys, do: Enum.map(@unit_types, & &1.key)

  @doc "Unit-type key → MUL API type-id lookup (nil for unknown keys)."
  def mul_type_id(key) do
    Enum.find_value(@unit_types, fn %{key: k, mul_type_id: id} -> if k == key, do: id end)
  end

  @doc """
  Faction entries grouped for the modal <select>, in render order.
  Each element is `{optgroup_label_or_nil, [faction_entry, ...]}`.
  """
  def faction_option_groups do
    Enum.map(@faction_option_groups, fn {label, group} ->
      {label, Enum.filter(@factions, &(&1.group == group))}
    end)
  end
end
