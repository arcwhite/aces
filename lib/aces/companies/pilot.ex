defmodule Aces.Companies.Pilot do
  @moduledoc """
  Schema for pilots in a mercenary company
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.Company

  @status_values ~w(active wounded deceased)
  @max_skill_level 10
  @default_skill_level 4

  # Skill progression costs based on Battletech: Aces rules
  @skill_costs %{
    0 => 60, 1 => 180, 2 => 360, 3 => 600,
    4 => 900, 5 => 1100, 6 => 1900, 7 => 3400,
    8 => 6000, 9 => 10000, 10 => 15000
  }

  schema "pilots" do
    field :name, :string
    field :callsign, :string
    field :description, :string
    field :portrait_url, :string
    field :skill_level, :integer, default: @default_skill_level
    field :edge_tokens, :integer, default: 1
    field :edge_abilities, {:array, :string}, default: []
    field :status, :string, default: "active"
    field :wounds, :integer, default: 0
    field :sp_earned, :integer, default: 0
    field :mvp_awards, :integer, default: 0
    field :sorties_participated, :integer, default: 0

    belongs_to :company, Company

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(pilot, attrs) do
    pilot
    |> cast(attrs, [:name, :callsign, :description, :portrait_url, :skill_level, 
                    :edge_tokens, :edge_abilities, :status, :wounds, :sp_earned, 
                    :mvp_awards, :sorties_participated, :company_id])
    |> validate_required([:name, :company_id])
    |> update_change(:name, &String.trim/1)
    |> update_change(:callsign, fn val -> if val, do: String.trim(val), else: val end)
    |> update_change(:description, fn val -> if val && String.trim(val) == "", do: nil, else: val end)
    |> validate_inclusion(:status, @status_values)
    |> validate_number(:skill_level, greater_than_or_equal_to: 0, less_than_or_equal_to: @max_skill_level)
    |> validate_number(:edge_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:wounds, greater_than_or_equal_to: 0)
    |> validate_number(:sp_earned, greater_than_or_equal_to: 0)
    |> validate_number(:mvp_awards, greater_than_or_equal_to: 0)
    |> validate_number(:sorties_participated, greater_than_or_equal_to: 0)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:callsign, max: 50)
    |> validate_portrait_url()
    |> unique_constraint([:company_id, :callsign], 
                        message: "Callsign must be unique within the company")
    |> foreign_key_constraint(:company_id)
  end

  @doc """
  Changeset for creating a new pilot during company creation
  """
  def creation_changeset(pilot, attrs) do
    pilot
    |> cast(attrs, [:name, :callsign, :description, :portrait_url])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:callsign, max: 50)
    |> put_change(:skill_level, @default_skill_level)
    |> put_change(:edge_tokens, 1)
    |> put_change(:status, "active")
  end

  @doc """
  Calculate the SP cost to upgrade a pilot's skill from one level to another
  """
  def calculate_skill_upgrade_cost(from_level, to_level) when from_level < to_level do
    if from_level >= 0 and to_level <= @max_skill_level do
      (from_level + 1)..to_level
      |> Enum.map(&Map.get(@skill_costs, &1, 0))
      |> Enum.sum()
    else
      {:error, :invalid_skill_levels}
    end
  end

  def calculate_skill_upgrade_cost(_from, _to), do: 0

  @doc """
  Get the SP cost for a specific skill level
  """
  def skill_level_cost(level) when level >= 0 and level <= @max_skill_level do
    Map.get(@skill_costs, level, 0)
  end

  def skill_level_cost(_), do: 0

  @doc """
  Apply wounds to a pilot
  """
  def apply_wound(pilot, severity \\ 1) do
    new_wounds = pilot.wounds + severity
    new_status = if new_wounds >= 3, do: "deceased", else: pilot.status
    
    %{pilot | wounds: new_wounds, status: new_status}
  end

  @doc """
  Check if pilot can be deployed (active and not heavily wounded)
  """
  def deployable?(pilot) do
    pilot.status == "active" and pilot.wounds < 3
  end

  @doc """
  Get display name for pilot (callsign or name)
  """
  def display_name(pilot) do
    if pilot.callsign && String.trim(pilot.callsign) != "" do
      "\"#{pilot.callsign}\" #{pilot.name}"
    else
      pilot.name
    end
  end

  # Private helper functions
  defp validate_portrait_url(changeset) do
    changeset
    |> validate_change(:portrait_url, fn :portrait_url, url ->
      if url && String.trim(url) != "" do
        if String.match?(url, ~r/^https?:\/\//) do
          []
        else
          [portrait_url: "must be a valid URL starting with http:// or https://"]
        end
      else
        []
      end
    end)
  end
end