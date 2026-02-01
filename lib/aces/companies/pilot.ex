defmodule Aces.Companies.Pilot do
  @moduledoc """
  Schema for pilots in a mercenary company
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.Company
  alias Aces.Companies.CompanyUnit
  alias Aces.Campaigns.PilotAllocation

  @status_values ~w(active wounded deceased)
  @max_skill_level 4
  @min_skill_level 0
  @default_skill_level 4

  # Skill progression costs based on Battletech: Aces rules (cumulative SP required to reach level)
  @skill_progression_costs %{
    4 => 0,     # Starting skill level
    3 => 400,   # 400 SP to reach skill 3
    2 => 900,   # 900 SP to reach skill 2  
    1 => 1900,  # 1900 SP to reach skill 1
    0 => 3400   # 3400 SP to reach skill 0
  }

  # Edge token progression costs (cumulative SP required to reach token count)
  @edge_token_costs %{
    1 => 0,     # Starting with 1 token
    2 => 60,    # 60 SP for 2nd token
    3 => 120,   # 120 SP for 3rd token
    4 => 200,   # 200 SP for 4th token
    5 => 300,   # 300 SP for 5th token
    6 => 420,   # 420 SP for 6th token
    7 => 560,   # 560 SP for 7th token
    8 => 720,   # 720 SP for 8th token
    9 => 900,   # 900 SP for 9th token
    10 => 1100  # 1100 SP for 10th token
  }

  # Edge abilities progression costs (cumulative SP required to reach ability count)
  @edge_ability_costs %{
    0 => 0,     # Starting with 0 abilities
    1 => 60,    # 60 SP for 1st ability
    2 => 180,   # 180 SP for 2nd ability
    3 => 360,   # 360 SP for 3rd ability
    4 => 600,   # 600 SP for 4th ability
    5 => 900    # 900 SP for 5th ability
  }

  @starting_sp 150

  # Available edge abilities for pilots
  @available_edge_abilities [
    "Assassin",
    "Bulwark",
    "Cautious",
    "Coolant Flush",
    "Forward Observer",
    "Jumping Jack",
    "Marksman",
    "Melee Specialist",
    "Nimble",
    "Patient",
    "Protector",
    "Speed Demon"
  ]

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
    
    # SP allocation tracking
    field :sp_allocated_to_skill, :integer, default: 0
    field :sp_allocated_to_edge_tokens, :integer, default: 0  # Start with 1 token for free
    field :sp_allocated_to_edge_abilities, :integer, default: 0
    field :sp_available, :integer, default: 150  # 150 starting SP

    belongs_to :company, Company
    has_one :assigned_unit, CompanyUnit
    has_many :allocations, PilotAllocation, foreign_key: :pilot_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(pilot, attrs) do
    pilot
    |> cast(attrs, [:name, :callsign, :description, :portrait_url, :skill_level, 
                    :edge_tokens, :status, :wounds, :sp_earned, 
                    :mvp_awards, :sorties_participated, :company_id,
                    :sp_allocated_to_skill, :sp_allocated_to_edge_tokens, 
                    :sp_allocated_to_edge_abilities, :sp_available])
    |> cast_edge_abilities_manually(attrs)
    |> validate_required([:name, :company_id])
    |> update_change(:name, &String.trim/1)
    |> update_change(:callsign, fn val -> if val, do: String.trim(val), else: val end)
    |> update_change(:description, fn val -> if val && String.trim(val) == "", do: nil, else: val end)
    |> validate_inclusion(:status, @status_values)
    |> validate_number(:skill_level, greater_than_or_equal_to: @min_skill_level, less_than_or_equal_to: @max_skill_level)
    |> validate_number(:edge_tokens, greater_than_or_equal_to: 1)
    |> validate_number(:wounds, greater_than_or_equal_to: 0)
    |> validate_number(:sp_earned, greater_than_or_equal_to: 0)
    |> validate_number(:mvp_awards, greater_than_or_equal_to: 0)
    |> validate_number(:sorties_participated, greater_than_or_equal_to: 0)
    |> validate_sp_allocation_limits()
    |> validate_number(:sp_available, greater_than_or_equal_to: 0)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:callsign, max: 50)
    |> validate_edge_abilities()
    |> validate_portrait_url()
    |> validate_sp_allocation_consistency()
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
    |> put_change(:sp_allocated_to_skill, 0)
    |> put_change(:sp_allocated_to_edge_tokens, 0)  # 1 edge token for free
    |> put_change(:sp_allocated_to_edge_abilities, 0)
    |> put_change(:sp_available, 150)  # 150 starting SP
  end

  @doc """
  Calculate the total SP required to reach a specific skill level
  """
  def skill_sp_required(skill_level) when skill_level >= @min_skill_level and skill_level <= @max_skill_level do
    Map.get(@skill_progression_costs, skill_level, 0)
  end

  def skill_sp_required(_), do: {:error, :invalid_skill_level}

  @doc """
  Calculate skill level from allocated SP
  """
  def calculate_skill_from_sp(sp_allocated) do
    @skill_progression_costs
    |> Enum.filter(fn {_level, required_sp} -> sp_allocated >= required_sp end)
    |> Enum.max_by(fn {_level, sp} -> sp end, fn -> {@default_skill_level, 0} end)
    |> elem(0)
  end

  @doc """
  Calculate edge tokens from allocated SP (includes free starting token)
  """
  def calculate_edge_tokens_from_sp(sp_allocated) do
    # Always get at least 1 token for free
    base_tokens = 1
    
    # Find additional tokens from SP allocation
    additional_tokens = @edge_token_costs
    |> Enum.filter(fn {tokens, required_sp} -> tokens > 1 and sp_allocated >= required_sp end)
    |> Enum.max_by(fn {_tokens, sp} -> sp end, fn -> {1, 0} end)
    |> elem(0)
    
    max(base_tokens, additional_tokens)
  end

  @doc """
  Calculate edge abilities count from allocated SP
  """
  def calculate_edge_abilities_from_sp(sp_allocated) do
    @edge_ability_costs
    |> Enum.filter(fn {_count, required_sp} -> sp_allocated >= required_sp end)
    |> Enum.max_by(fn {_count, sp} -> sp end, fn -> {0, 0} end)
    |> elem(0)
  end

  @doc """
  Get SP required for specific edge token count
  """
  def edge_tokens_sp_required(token_count) do
    Map.get(@edge_token_costs, token_count, {:error, :invalid_token_count})
  end

  @doc """
  Get SP required for specific edge ability count
  """
  def edge_abilities_sp_required(ability_count) do
    Map.get(@edge_ability_costs, ability_count, {:error, :invalid_ability_count})
  end

  @doc """
  Get list of available edge abilities
  """
  def available_edge_abilities do
    @available_edge_abilities
  end

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

  @doc """
  Allocate SP to a specific category and update derived fields
  """
  def allocate_sp(pilot, sp_amount, category) when category in [:skill, :edge_tokens, :edge_abilities] do
    case category do
      :skill ->
        new_sp_skill = pilot.sp_allocated_to_skill + sp_amount
        new_skill_level = calculate_skill_from_sp(new_sp_skill)
        new_sp_available = pilot.sp_available - sp_amount
        
        %{pilot | 
          sp_allocated_to_skill: new_sp_skill,
          skill_level: new_skill_level,
          sp_available: new_sp_available}

      :edge_tokens ->
        new_sp_tokens = pilot.sp_allocated_to_edge_tokens + sp_amount
        new_edge_tokens = calculate_edge_tokens_from_sp(new_sp_tokens)
        new_sp_available = pilot.sp_available - sp_amount
        
        %{pilot | 
          sp_allocated_to_edge_tokens: new_sp_tokens,
          edge_tokens: new_edge_tokens,
          sp_available: new_sp_available}

      :edge_abilities ->
        new_sp_abilities = pilot.sp_allocated_to_edge_abilities + sp_amount
        new_sp_available = pilot.sp_available - sp_amount
        
        # Keep existing edge abilities list, just track the SP allocation
        %{pilot | 
          sp_allocated_to_edge_abilities: new_sp_abilities,
          sp_available: new_sp_available}
    end
  end

  # Private helper functions
  defp cast_edge_abilities_manually(changeset, attrs) do
    case Map.get(attrs, :edge_abilities) || Map.get(attrs, "edge_abilities") do
      nil -> changeset
      abilities when is_list(abilities) -> 
        put_change(changeset, :edge_abilities, abilities)
      json_string when is_binary(json_string) ->
        case Jason.decode(json_string) do
          {:ok, abilities} when is_list(abilities) ->
            put_change(changeset, :edge_abilities, abilities)
          _ ->
            add_error(changeset, :edge_abilities, "invalid JSON format")
        end
      _ ->
        add_error(changeset, :edge_abilities, "must be a list or JSON string")
    end
  end

  defp validate_sp_allocation_limits(changeset) do
    changeset
    |> validate_number(:sp_allocated_to_skill, greater_than_or_equal_to: 0)
    |> validate_number(:sp_allocated_to_edge_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:sp_allocated_to_edge_abilities, greater_than_or_equal_to: 0)
    |> validate_individual_sp_limit(:sp_allocated_to_skill)
    |> validate_individual_sp_limit(:sp_allocated_to_edge_tokens)
    |> validate_individual_sp_limit(:sp_allocated_to_edge_abilities)
    |> validate_total_sp_allocation()
  end

  defp validate_individual_sp_limit(changeset, field) do
    validate_change(changeset, field, fn ^field, sp_value ->
      sp_earned = get_field(changeset, :sp_earned) || 0
      max_sp = @starting_sp + sp_earned
      
      if sp_value > max_sp do
        [{field, "cannot exceed total available SP (#{max_sp})"}]
      else
        []
      end
    end)
  end

  defp validate_total_sp_allocation(changeset) do
    skill_sp = get_field(changeset, :sp_allocated_to_skill) || 0
    tokens_sp = get_field(changeset, :sp_allocated_to_edge_tokens) || 0
    abilities_sp = get_field(changeset, :sp_allocated_to_edge_abilities) || 0
    sp_earned = get_field(changeset, :sp_earned) || 0
    
    total_allocated = skill_sp + tokens_sp + abilities_sp
    total_available = @starting_sp + sp_earned
    
    if total_allocated > total_available do
      add_error(changeset, :base, "Total SP allocation (#{total_allocated}) exceeds available SP (#{total_available})")
    else
      changeset
    end
  end

  defp validate_sp_allocation_consistency(changeset) do
    changeset
    |> validate_change(:sp_available, fn :sp_available, sp_available ->
      skill_sp = get_field(changeset, :sp_allocated_to_skill) || 0
      tokens_sp = get_field(changeset, :sp_allocated_to_edge_tokens) || 0
      abilities_sp = get_field(changeset, :sp_allocated_to_edge_abilities) || 0
      sp_earned = get_field(changeset, :sp_earned) || 0
      
      total_allocated = skill_sp + tokens_sp + abilities_sp
      total_sp = @starting_sp + sp_earned
      
      if total_allocated + sp_available != total_sp do
        [sp_available: "SP allocation doesn't add up correctly"]
      else
        []
      end
    end)
    |> validate_derived_fields()
  end

  defp validate_derived_fields(changeset) do
    changeset
    |> validate_change(:skill_level, fn :skill_level, skill_level ->
      sp_allocated = get_field(changeset, :sp_allocated_to_skill) || 0
      expected_skill = calculate_skill_from_sp(sp_allocated)
      
      if skill_level != expected_skill do
        [skill_level: "Skill level doesn't match allocated SP"]
      else
        []
      end
    end)
    |> validate_change(:edge_tokens, fn :edge_tokens, edge_tokens ->
      sp_allocated = get_field(changeset, :sp_allocated_to_edge_tokens) || 0
      expected_tokens = calculate_edge_tokens_from_sp(sp_allocated)
      
      if edge_tokens != expected_tokens do
        [edge_tokens: "Edge tokens don't match allocated SP"]
      else
        []
      end
    end)
  end


  defp validate_edge_abilities(changeset) do
    changeset
    |> validate_change(:edge_abilities, fn :edge_abilities, abilities ->
      cond do
        !is_list(abilities) ->
          [edge_abilities: "must be a list"]
        
        # Check if all abilities are valid
        true ->
          invalid_abilities = Enum.reject(abilities, fn ability -> ability in @available_edge_abilities end)
          cond do
            length(invalid_abilities) > 0 ->
              [edge_abilities: "contains invalid abilities: #{Enum.join(invalid_abilities, ", ")}"]

            # Check if abilities count matches allocated SP
            length(abilities) > calculate_edge_abilities_from_sp(get_field(changeset, :sp_allocated_to_edge_abilities) || 0) ->
              [edge_abilities: "too many abilities selected for allocated SP"]

            true ->
              []
          end
      end
    end)
  end

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