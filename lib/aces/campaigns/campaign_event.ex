defmodule Aces.Campaigns.CampaignEvent do
  @moduledoc """
  Campaign event schema - tracks timeline of events during a campaign.

  Events track who performed the action (user_id) so that multi-user
  campaigns can show which collaborator made each change.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Accounts.User
  alias Aces.Campaigns.Campaign

  @event_types ~w(
    campaign_started campaign_completed campaign_failed
    sortie_started sortie_completed sortie_failed
    pilot_hired pilot_wounded pilot_killed pilot_recovered
    unit_purchased unit_sold unit_destroyed unit_repaired unit_refitted
    keyword_gained sp_awarded mvp_awarded
  )

  schema "campaign_events" do
    field :event_type, :string
    field :event_data, :map, default: %{}
    field :description, :string
    field :occurred_at, :utc_datetime

    belongs_to :campaign, Campaign
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :event_data, :description, :occurred_at, :user_id])
    |> validate_required([:event_type, :description, :occurred_at])
    |> validate_inclusion(:event_type, @event_types)
    |> foreign_key_constraint(:campaign_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Creates a new campaign event with automatic timestamp.

  Accepts optional `user_id` to track which user performed the action.
  """
  def creation_changeset(event, attrs) do
    event
    |> cast(attrs, [:campaign_id, :user_id, :event_type, :event_data, :description])
    |> validate_required([:campaign_id, :event_type, :description])
    |> validate_inclusion(:event_type, @event_types)
    |> put_change(:occurred_at, DateTime.truncate(DateTime.utc_now(), :second))
    |> foreign_key_constraint(:campaign_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Create event data for sortie completion
  """
  def sortie_completed_data(sortie) do
    %{
      sortie_id: sortie.id,
      mission_number: sortie.mission_number,
      was_successful: sortie.was_successful,
      net_earnings: sortie.net_earnings,
      keywords_gained: sortie.keywords_gained || []
    }
  end

  @doc """
  Create event data for pilot hiring
  """
  def pilot_hired_data(pilot, cost_sp) do
    %{
      pilot_id: pilot.id,
      pilot_name: pilot.name,
      pilot_callsign: pilot.callsign,
      cost_sp: cost_sp
    }
  end

  @doc """
  Create event data for unit purchase
  """
  def unit_purchased_data(company_unit, cost_sp) do
    %{
      company_unit_id: company_unit.id,
      unit_name: company_unit.master_unit.name,
      unit_variant: company_unit.master_unit.variant,
      cost_sp: cost_sp,
      custom_name: company_unit.custom_name
    }
  end

  @doc """
  Create event data for MVP award
  """
  def mvp_awarded_data(pilot, sortie) do
    %{
      pilot_id: pilot.id,
      pilot_name: pilot.name,
      pilot_callsign: pilot.callsign,
      sortie_id: sortie.id,
      sortie_name: sortie.name,
      mission_number: sortie.mission_number,
      sp_bonus: 20
    }
  end

  @doc """
  Generate description from event type and data
  """
  def generate_description(event_type, event_data) do
    case event_type do
      "campaign_started" ->
        "Campaign started"

      "campaign_completed" ->
        "Campaign completed successfully"

      "campaign_failed" ->
        "Campaign failed"

      "sortie_started" ->
        "Started Sortie #{event_data["mission_number"]}: #{event_data["sortie_name"]}"

      "sortie_completed" ->
        result = if event_data["was_successful"], do: "Success", else: "Failure"
        earnings = event_data["net_earnings"] || 0
        "Completed Sortie #{event_data["mission_number"]}: #{result}, #{earnings} SP earned"

      "pilot_hired" ->
        name = pilot_display_name(event_data["pilot_name"], event_data["pilot_callsign"])
        cost = event_data["cost_sp"] || 0
        "Hired pilot #{name} for #{cost} SP"

      "pilot_wounded" ->
        name = pilot_display_name(event_data["pilot_name"], event_data["pilot_callsign"])
        "#{name} was wounded in action"

      "pilot_killed" ->
        name = pilot_display_name(event_data["pilot_name"], event_data["pilot_callsign"])
        "#{name} was killed in action"

      "pilot_recovered" ->
        name = pilot_display_name(event_data["pilot_name"], event_data["pilot_callsign"])
        "#{name} recovered from wounds"

      "unit_purchased" ->
        unit_name = unit_display_name(event_data["unit_name"], event_data["unit_variant"], event_data["custom_name"])
        cost = event_data["cost_sp"] || 0
        "Purchased #{unit_name} for #{cost} SP"

      "unit_sold" ->
        unit_name = unit_display_name(event_data["unit_name"], event_data["unit_variant"], event_data["custom_name"])
        value = event_data["value_sp"] || 0
        "Sold #{unit_name} for #{value} SP"

      "unit_destroyed" ->
        unit_name = unit_display_name(event_data["unit_name"], event_data["unit_variant"], event_data["custom_name"])
        "#{unit_name} was destroyed in action"

      "unit_repaired" ->
        unit_name = unit_display_name(event_data["unit_name"], event_data["unit_variant"], event_data["custom_name"])
        cost = event_data["repair_cost"] || 0
        "Repaired #{unit_name} for #{cost} SP"

      "unit_refitted" ->
        # Description is provided directly in the event, not generated from data
        event_data["description"] || "Unit refitted"

      "keyword_gained" ->
        keyword = event_data["keyword"] || "Unknown"
        "Gained campaign keyword: #{keyword}"

      "mvp_awarded" ->
        name = pilot_display_name(event_data["pilot_name"], event_data["pilot_callsign"])
        sortie = event_data["mission_number"]
        "#{name} awarded MVP for Sortie #{sortie} (+20 SP)"

      _ ->
        "Campaign event: #{event_type}"
    end
  end

  defp pilot_display_name(name, nil), do: name
  defp pilot_display_name(name, callsign), do: "#{name} '#{callsign}'"

  defp unit_display_name(name, variant, nil), do: "#{name} #{variant}"
  defp unit_display_name(name, variant, custom_name), do: "#{custom_name} (#{name} #{variant})"
end
