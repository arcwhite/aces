defmodule Aces.Campaigns.PilotCampaignStats do
  @moduledoc """
  Pilot campaign stats schema - tracks per-campaign pilot performance
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.Pilot
  alias Aces.Campaigns.Campaign

  schema "pilot_campaign_stats" do
    field :sorties_participated, :integer, default: 0
    field :sp_earned, :integer, default: 0
    field :mvp_awards, :integer, default: 0

    belongs_to :pilot, Pilot
    belongs_to :campaign, Campaign

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(stats, attrs) do
    stats
    |> cast(attrs, [:sorties_participated, :sp_earned, :mvp_awards])
    |> validate_number(:sorties_participated, greater_than_or_equal_to: 0)
    |> validate_number(:sp_earned, greater_than_or_equal_to: 0)
    |> validate_number(:mvp_awards, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:pilot_id)
    |> foreign_key_constraint(:campaign_id)
  end

  def creation_changeset(stats, attrs) do
    stats
    |> cast(attrs, [:pilot_id, :campaign_id])
    |> validate_required([:pilot_id, :campaign_id])
    |> put_change(:sorties_participated, 0)
    |> put_change(:sp_earned, 0)
    |> put_change(:mvp_awards, 0)
    |> unique_constraint([:pilot_id, :campaign_id])
    |> foreign_key_constraint(:pilot_id)
    |> foreign_key_constraint(:campaign_id)
  end

  @doc """
  Record sortie participation for a pilot
  """
  def record_sortie_participation(%__MODULE__{} = stats, sp_earned) do
    %{stats |
      sorties_participated: stats.sorties_participated + 1,
      sp_earned: stats.sp_earned + sp_earned
    }
  end

  @doc """
  Record MVP award for a pilot
  """
  def record_mvp_award(%__MODULE__{} = stats, bonus_sp \\ 20) do
    %{stats |
      mvp_awards: stats.mvp_awards + 1,
      sp_earned: stats.sp_earned + bonus_sp
    }
  end
end
