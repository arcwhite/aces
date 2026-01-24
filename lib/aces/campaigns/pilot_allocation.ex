defmodule Aces.Campaigns.PilotAllocation do
  @moduledoc """
  Ecto schema for pilot SP allocations.

  This table stores the history of how pilots allocate their SP (Support Points)
  to the three pools: Skill, Edge Tokens, and Edge Abilities.

  There are two allocation types:
  - "initial" - The 150 SP allocation when a pilot is first created (sortie_id is nil)
  - "sortie" - SP allocated after completing a sortie (sortie_id is required)

  A pilot's current stats are computed by summing all their allocation records.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.Pilot
  alias Aces.Campaigns.Sortie

  @allocation_types ~w(initial sortie)

  schema "pilot_allocations" do
    field :allocation_type, :string
    field :sp_to_skill, :integer, default: 0
    field :sp_to_tokens, :integer, default: 0
    field :sp_to_abilities, :integer, default: 0
    field :edge_abilities_gained, {:array, :string}, default: []
    field :total_sp, :integer, default: 0

    belongs_to :pilot, Pilot
    belongs_to :sortie, Sortie

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a pilot allocation.
  """
  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :allocation_type,
      :sp_to_skill,
      :sp_to_tokens,
      :sp_to_abilities,
      :edge_abilities_gained,
      :total_sp,
      :pilot_id,
      :sortie_id
    ])
    |> validate_required([:allocation_type, :pilot_id])
    |> validate_inclusion(:allocation_type, @allocation_types)
    |> validate_number(:sp_to_skill, greater_than_or_equal_to: 0)
    |> validate_number(:sp_to_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:sp_to_abilities, greater_than_or_equal_to: 0)
    |> validate_number(:total_sp, greater_than_or_equal_to: 0)
    |> validate_total_sp_sum()
    |> validate_sortie_required_for_sortie_type()
    |> validate_edge_abilities()
    |> foreign_key_constraint(:pilot_id)
    |> foreign_key_constraint(:sortie_id)
    |> unique_constraint([:sortie_id, :pilot_id],
      name: :pilot_allocations_sortie_pilot_unique,
      message: "pilot already has an allocation for this sortie"
    )
    |> unique_constraint(:pilot_id,
      name: :pilot_allocations_initial_unique,
      message: "pilot already has an initial allocation"
    )
  end

  @doc """
  Creates a changeset for an initial allocation (150 SP when pilot is created).
  """
  def initial_changeset(allocation, attrs) do
    attrs =
      attrs
      |> Map.put(:allocation_type, "initial")
      |> Map.put(:sortie_id, nil)

    changeset(allocation, attrs)
  end

  @doc """
  Creates a changeset for a sortie allocation (SP earned after completing a sortie).
  """
  def sortie_changeset(allocation, attrs) do
    attrs = Map.put(attrs, :allocation_type, "sortie")

    changeset(allocation, attrs)
  end

  # Validates that total_sp equals the sum of the three allocation pools
  defp validate_total_sp_sum(changeset) do
    sp_to_skill = get_field(changeset, :sp_to_skill) || 0
    sp_to_tokens = get_field(changeset, :sp_to_tokens) || 0
    sp_to_abilities = get_field(changeset, :sp_to_abilities) || 0
    total_sp = get_field(changeset, :total_sp) || 0

    expected_total = sp_to_skill + sp_to_tokens + sp_to_abilities

    if total_sp != expected_total do
      add_error(
        changeset,
        :total_sp,
        "must equal the sum of sp_to_skill, sp_to_tokens, and sp_to_abilities (expected #{expected_total}, got #{total_sp})"
      )
    else
      changeset
    end
  end

  # Validates that sortie_id is required when allocation_type is "sortie"
  defp validate_sortie_required_for_sortie_type(changeset) do
    allocation_type = get_field(changeset, :allocation_type)
    sortie_id = get_field(changeset, :sortie_id)

    cond do
      allocation_type == "sortie" and is_nil(sortie_id) ->
        add_error(changeset, :sortie_id, "is required for sortie allocations")

      allocation_type == "initial" and not is_nil(sortie_id) ->
        add_error(changeset, :sortie_id, "must be nil for initial allocations")

      true ->
        changeset
    end
  end

  # Validates that edge_abilities_gained contains only valid ability names
  defp validate_edge_abilities(changeset) do
    validate_change(changeset, :edge_abilities_gained, fn :edge_abilities_gained, abilities ->
      available = Pilot.available_edge_abilities()

      invalid_abilities = Enum.reject(abilities, &(&1 in available))

      if invalid_abilities != [] do
        [{:edge_abilities_gained, "contains invalid abilities: #{Enum.join(invalid_abilities, ", ")}"}]
      else
        []
      end
    end)
  end

  @doc """
  Returns the list of valid allocation types.
  """
  def allocation_types, do: @allocation_types
end
