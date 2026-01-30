defmodule Aces.Campaigns.Sortie do
  @moduledoc """
  Sortie schema - represents an individual mission within a campaign
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.Pilot
  alias Aces.Campaigns.{Campaign, Deployment, PilotAllocation}

  @sortie_status ~w(setup in_progress finalizing failed completed)

  schema "sorties" do
    field :mission_number, :string
    field :name, :string
    field :description, :string
    field :pv_limit, :integer
    field :status, :string, default: "setup"

    # Recon options
    field :recon_notes, :string
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
    field :pilot_sp_cost, :integer, default: 0
    field :sp_per_participating_pilot, :integer, default: 0
    field :keywords_gained, {:array, :string}, default: []

    # Finalization wizard progress
    field :finalization_step, :string  # "outcome" | "damage" | "costs" | "pilots" | "spend_sp" | "summary" | nil

    # Pilot SP allocations made in spend_sp step (stored in pilot_allocations table)
    has_many :pilot_allocations, PilotAllocation

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
      :recon_notes, :recon_options, :recon_total_cost, :was_successful,
      :primary_objective_income, :secondary_objectives_income, :waypoints_income,
      :rearming_cost, :total_income, :total_expenses, :net_earnings, :pilot_sp_cost,
      :sp_per_participating_pilot, :keywords_gained, :mvp_pilot_id,
      :started_at, :completed_at, :finalization_step
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
    |> cast(attrs, [:campaign_id, :mission_number, :name, :description, :pv_limit, :force_commander_id, :recon_notes, :recon_options, :recon_total_cost])
    |> validate_required([:campaign_id, :mission_number, :name, :pv_limit])
    |> validate_format(:mission_number, ~r/^[0-9]+[A-Z]?$/, message: "must be a number, optionally followed by a letter (e.g., 1, 2A, 3B)")
    |> validate_number(:pv_limit, greater_than: 0)
    |> validate_number(:recon_total_cost, greater_than_or_equal_to: 0)
    |> put_change(:status, "setup")
    |> maybe_calculate_recon_total_cost()
    |> unique_constraint([:campaign_id, :mission_number],
      name: :sorties_campaign_mission_active_unique,
      message: "already exists for an active sortie in this campaign"
    )
    |> foreign_key_constraint(:campaign_id)
    |> foreign_key_constraint(:force_commander_id)
  end

  def start_changeset(sortie, attrs \\ %{}) do
    sortie
    |> cast(attrs, [:force_commander_id, :started_at])
    |> validate_required([:force_commander_id])
    |> validate_status_is_setup()
    |> validate_has_deployments()
    |> validate_has_named_pilot()
    |> put_change(:status, "in_progress")
    |> put_change(:started_at, DateTime.truncate(DateTime.utc_now(), :second))
    |> foreign_key_constraint(:force_commander_id)
  end

  defp validate_status_is_setup(changeset) do
    case get_field(changeset, :status) do
      "setup" -> changeset
      status -> add_error(changeset, :status, "must be in setup state to start (currently #{status})")
    end
  end

  defp validate_has_deployments(changeset) do
    deployments = changeset.data.deployments || []

    if length(deployments) > 0 do
      changeset
    else
      add_error(changeset, :deployments, "must have at least one unit deployed")
    end
  end

  defp validate_has_named_pilot(changeset) do
    deployments = changeset.data.deployments || []
    has_named_pilot = Enum.any?(deployments, & &1.pilot_id != nil)

    if has_named_pilot do
      changeset
    else
      add_error(changeset, :deployments, "must have at least one deployment with a named pilot")
    end
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
    |> put_change(:completed_at, DateTime.truncate(DateTime.utc_now(), :second))
    |> calculate_totals()
    |> foreign_key_constraint(:mvp_pilot_id)
  end

  def finalize_changeset(sortie) do
    sortie
    |> put_change(:status, "completed")
    |> validate_inclusion(:status, @sortie_status)
  end

  @doc """
  Changeset for marking a sortie as failed.
  Used when the player clicks "Sortie Failed" - no outcomes are applied.
  """
  def fail_changeset(sortie, attrs \\ %{}) do
    sortie
    |> change()
    |> cast(attrs, [:recon_notes])
    |> validate_status_is_in_progress()
    |> put_change(:status, "failed")
    |> put_change(:was_successful, false)
    |> put_change(:completed_at, DateTime.truncate(DateTime.utc_now(), :second))
  end

  @doc """
  Changeset for beginning the finalization wizard.
  Transitions from in_progress to finalizing status.
  """
  def begin_finalization_changeset(sortie) do
    sortie
    |> change()
    |> validate_status_is_in_progress()
    |> put_change(:status, "finalizing")
    |> put_change(:finalization_step, "outcome")
  end

  @doc """
  Changeset for updating finalization wizard progress.
  """
  def finalization_step_changeset(sortie, step, attrs \\ %{}) do
    sortie
    |> cast(attrs, [
      :primary_objective_income, :secondary_objectives_income, :waypoints_income,
      :keywords_gained, :sp_per_participating_pilot, :recon_notes
    ])
    |> put_change(:finalization_step, step)
  end

  defp validate_status_is_in_progress(changeset) do
    case get_field(changeset, :status) do
      "in_progress" -> changeset
      status -> add_error(changeset, :status, "must be in progress to complete (currently #{status})")
    end
  end

  defp maybe_calculate_recon_total_cost(changeset) do
    # Only auto-calculate if recon_total_cost was not explicitly provided
    case {get_change(changeset, :recon_total_cost), get_change(changeset, :recon_options)} do
      {nil, recon_options} when is_list(recon_options) ->
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
      true -> put_change(changeset, :status, "completed")
      false -> put_change(changeset, :status, "failed")
      _ -> changeset
    end
  end
end
