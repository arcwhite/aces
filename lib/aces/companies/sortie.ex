defmodule Aces.Companies.Sortie do
  @moduledoc """
  Sortie schema - represents an individual mission within a campaign
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.{Campaign, Pilot, Deployment}

  @sortie_status ~w(setup in_progress success failed completed)

  schema "sorties" do
    field :mission_number, :integer
    field :name, :string
    field :description, :string
    field :pv_limit, :integer
    field :status, :string, default: "setup"

    # Recon options
    field :recon_options, {:array, :map}, default: []
    field :recon_total_cost, :integer, default: 0

    # Post-battle results
    field :was_successful, :boolean
    field :primary_objective_income, :integer, default: 0
    field :secondary_objectives_income, :integer, default: 0
    field :waypoints_income, :integer, default: 0
    field :rearming_cost, :integer, default: 0
    field :total_income, :integer, default: 0
    field :total_expenses, :integer, default: 0
    field :net_earnings, :integer, default: 0
    field :sp_per_participating_pilot, :integer, default: 0
    field :keywords_gained, {:array, :string}, default: []

    # Metadata
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :campaign, Campaign
    belongs_to :force_commander, Pilot, foreign_key: :force_commander_id
    belongs_to :mvp_pilot, Pilot, foreign_key: :mvp_pilot_id
    has_many :deployments, Deployment, preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(sortie, attrs) do
    sortie
    |> cast(attrs, [
      :name, :description, :pv_limit, :status, :force_commander_id,
      :recon_options, :recon_total_cost, :was_successful,
      :primary_objective_income, :secondary_objectives_income, :waypoints_income,
      :rearming_cost, :total_income, :total_expenses, :net_earnings,
      :sp_per_participating_pilot, :keywords_gained, :mvp_pilot_id,
      :started_at, :completed_at
    ])
    |> validate_required([:name, :pv_limit, :status])
    |> validate_inclusion(:status, @sortie_status)
    |> validate_number(:pv_limit, greater_than: 0)
    |> validate_number(:recon_total_cost, greater_than_or_equal_to: 0)
    |> validate_number(:sp_per_participating_pilot, greater_than_or_equal_to: 0)
    |> maybe_calculate_recon_total_cost()
    |> foreign_key_constraint(:campaign_id)
    |> foreign_key_constraint(:force_commander_id)
    |> foreign_key_constraint(:mvp_pilot_id)
  end

  def creation_changeset(sortie, attrs) do
    sortie
    |> cast(attrs, [:campaign_id, :mission_number, :name, :description, :pv_limit, :force_commander_id, :recon_options])
    |> validate_required([:campaign_id, :mission_number, :name, :pv_limit])
    |> validate_number(:mission_number, greater_than: 0)
    |> validate_number(:pv_limit, greater_than: 0)
    |> put_change(:status, "setup")
    |> maybe_calculate_recon_total_cost()
    |> unique_constraint([:campaign_id, :mission_number])
    |> foreign_key_constraint(:campaign_id)
    |> foreign_key_constraint(:force_commander_id)
  end

  def start_changeset(sortie, attrs \\ %{}) do
    sortie
    |> cast(attrs, [:force_commander_id, :started_at])
    |> validate_required([:force_commander_id])
    |> put_change(:status, "in_progress")
    |> put_change(:started_at, DateTime.utc_now())
    |> foreign_key_constraint(:force_commander_id)
  end

  def completion_changeset(sortie, attrs) do
    sortie
    |> cast(attrs, [
      :was_successful, :primary_objective_income, :secondary_objectives_income,
      :waypoints_income, :rearming_cost, :mvp_pilot_id, :sp_per_participating_pilot,
      :keywords_gained
    ])
    |> validate_required([:was_successful, :sp_per_participating_pilot])
    |> validate_number(:primary_objective_income, greater_than_or_equal_to: 0)
    |> validate_number(:secondary_objectives_income, greater_than_or_equal_to: 0)
    |> validate_number(:waypoints_income, greater_than_or_equal_to: 0)
    |> validate_number(:rearming_cost, greater_than_or_equal_to: 0)
    |> validate_number(:sp_per_participating_pilot, greater_than_or_equal_to: 0)
    |> put_completed_status()
    |> put_change(:completed_at, DateTime.utc_now())
    |> calculate_totals()
    |> foreign_key_constraint(:mvp_pilot_id)
  end

  def finalize_changeset(sortie) do
    sortie
    |> put_change(:status, "completed")
    |> validate_inclusion(:status, @sortie_status)
  end

  defp maybe_calculate_recon_total_cost(changeset) do
    case get_change(changeset, :recon_options) do
      recon_options when is_list(recon_options) ->
        total_cost = 
          recon_options
          |> Enum.map(&Map.get(&1, "cost_sp", 0))
          |> Enum.sum()
        
        put_change(changeset, :recon_total_cost, total_cost)

      _ ->
        changeset
    end
  end

  defp calculate_totals(changeset) do
    primary = get_field(changeset, :primary_objective_income) || 0
    secondary = get_field(changeset, :secondary_objectives_income) || 0
    waypoints = get_field(changeset, :waypoints_income) || 0
    recon_cost = get_field(changeset, :recon_total_cost) || 0
    rearming = get_field(changeset, :rearming_cost) || 0

    total_income = primary + secondary + waypoints - recon_cost
    total_expenses = rearming
    net_earnings = total_income - total_expenses

    changeset
    |> put_change(:total_income, total_income)
    |> put_change(:total_expenses, total_expenses)
    |> put_change(:net_earnings, net_earnings)
  end

  defp put_completed_status(changeset) do
    case get_change(changeset, :was_successful) do
      true -> put_change(changeset, :status, "success")
      false -> put_change(changeset, :status, "failed")
      _ -> changeset
    end
  end

  @doc """
  Check if sortie can be started (has force commander and deployments)
  """
  def can_start?(%__MODULE__{force_commander_id: nil}), do: false
  def can_start?(%__MODULE__{status: "setup", deployments: deployments}) when length(deployments) > 0, do: true
  def can_start?(_), do: false

  @doc """
  Get deployments with participating pilots (exclude unnamed crew)
  """
  def participating_pilot_deployments(%__MODULE__{deployments: deployments}) do
    Enum.filter(deployments, & &1.pilot_id)
  end

  @doc """
  Calculate total PV deployed for this sortie
  """
  def calculate_deployed_pv(%__MODULE__{deployments: deployments}) do
    deployments
    |> Enum.map(fn deployment ->
      if deployment.company_unit && deployment.company_unit.master_unit do
        deployment.company_unit.master_unit.point_value || 0
      else
        0
      end
    end)
    |> Enum.sum()
  end
end