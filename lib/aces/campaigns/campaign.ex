defmodule Aces.Campaigns.Campaign do
  @moduledoc """
  Campaign schema - represents a multi-month deployment for a mercenary company
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.Company
  alias Aces.Campaigns.{Sortie, CampaignEvent}

  @difficulty_levels ~w(rookie standard veteran elite legendary)
  @campaign_status ~w(active completed failed)

  schema "campaigns" do
    field :name, :string
    field :description, :string
    field :status, :string, default: "active"
    field :difficulty_level, :string, default: "standard"
    field :pv_limit_modifier, :float, default: 1.0
    field :reward_modifier, :float, default: 1.0
    field :experience_modifier, :float, default: 1.0
    field :warchest_balance, :integer, default: 0
    field :keywords, {:array, :string}, default: []
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :company, Company
    has_many :sorties, Sortie, preload_order: [asc: :mission_number]
    has_many :campaign_events, CampaignEvent, preload_order: [desc: :occurred_at]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(campaign, attrs) do
    campaign
    |> cast(attrs, [:name, :description, :status, :difficulty_level, :warchest_balance, :keywords, :started_at, :completed_at])
    |> validate_required([:name, :status, :difficulty_level])
    |> validate_inclusion(:status, @campaign_status)
    |> validate_inclusion(:difficulty_level, @difficulty_levels)
    |> validate_number(:warchest_balance, greater_than_or_equal_to: 0)
    |> update_modifiers_based_on_difficulty()
    |> maybe_set_started_at()
  end

  def creation_changeset(campaign, attrs) do
    campaign
    |> cast(attrs, [:company_id, :name, :description, :difficulty_level, :warchest_balance, :keywords])
    |> validate_required([:company_id, :name, :difficulty_level])
    |> validate_inclusion(:difficulty_level, @difficulty_levels)
    |> validate_number(:warchest_balance, greater_than_or_equal_to: 0)
    |> put_change(:status, "active")
    |> put_change(:started_at, DateTime.truncate(DateTime.utc_now(), :second))
    |> update_modifiers_based_on_difficulty()
    |> foreign_key_constraint(:company_id)
    |> unique_constraint([:company_id], name: :campaigns_company_active_unique, message: "Company can only have one active campaign")
  end

  def completion_changeset(campaign, attrs \\ %{}) do
    campaign
    |> cast(attrs, [:status, :completed_at])
    |> validate_required([:status])
    |> validate_inclusion(:status, @campaign_status)
    |> maybe_set_completed_at()
  end

  defp update_modifiers_based_on_difficulty(changeset) do
    case get_change(changeset, :difficulty_level) do
      "rookie" ->
        changeset
        |> put_change(:pv_limit_modifier, 1.2)
        |> put_change(:reward_modifier, 1.2)

      "standard" ->
        changeset
        |> put_change(:pv_limit_modifier, 1.0)
        |> put_change(:reward_modifier, 1.0)

      "veteran" ->
        changeset
        |> put_change(:pv_limit_modifier, 0.9)
        |> put_change(:reward_modifier, 0.9)

      "elite" ->
        changeset
        |> put_change(:pv_limit_modifier, 0.8)
        |> put_change(:reward_modifier, 0.8)

      "legendary" ->
        changeset
        |> put_change(:pv_limit_modifier, 0.7)
        |> put_change(:reward_modifier, 0.7)

      _ ->
        changeset
    end
  end

  defp maybe_set_started_at(changeset) do
    if get_change(changeset, :status) == "active" and get_field(changeset, :started_at) == nil do
      put_change(changeset, :started_at, DateTime.truncate(DateTime.utc_now(), :second))
    else
      changeset
    end
  end

  defp maybe_set_completed_at(changeset) do
    case get_change(changeset, :status) do
      status when status in ["completed", "failed"] ->
        if get_field(changeset, :completed_at) == nil do
          put_change(changeset, :completed_at, DateTime.truncate(DateTime.utc_now(), :second))
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
