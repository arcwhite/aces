defmodule Aces.PubSub.Broadcasts do
  @moduledoc """
  Centralized PubSub broadcasting for real-time updates.

  Provides topic naming and broadcast helpers for Company, Campaign, and Sortie
  entities. All broadcasts use consistent message formats for easy handling.

  ## Topic Structure

  - `company:{id}` - Company membership and invitation changes
  - `campaign:{id}` - Campaign, unit, and pilot changes
  - `sortie:{id}` - Sortie-specific changes (damage, casualties, variants)

  ## Message Format

  All broadcasts use the tuple format:

      {:entity_updated, %{event: event_name, payload: payload}}

  where `entity` is company, campaign, or sortie.
  """

  @pubsub Aces.PubSub

  # Topic builders
  def company_topic(id), do: "company:#{id}"
  def campaign_topic(id), do: "campaign:#{id}"
  def sortie_topic(id), do: "sortie:#{id}"

  # Subscribe helpers
  def subscribe_company(company_id) do
    Phoenix.PubSub.subscribe(@pubsub, company_topic(company_id))
  end

  def subscribe_campaign(campaign_id) do
    Phoenix.PubSub.subscribe(@pubsub, campaign_topic(campaign_id))
  end

  def subscribe_sortie(sortie_id) do
    Phoenix.PubSub.subscribe(@pubsub, sortie_topic(sortie_id))
  end

  # Company broadcasts
  def broadcast_company_update(company_id, event, payload \\ %{}) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      company_topic(company_id),
      {:company_updated, %{event: event, payload: payload}}
    )
  end

  # Campaign broadcasts
  def broadcast_campaign_update(campaign_id, event, payload \\ %{}) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      campaign_topic(campaign_id),
      {:campaign_updated, %{event: event, payload: payload}}
    )
  end

  # Sortie broadcasts
  def broadcast_sortie_update(sortie_id, event, payload \\ %{}) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      sortie_topic(sortie_id),
      {:sortie_updated, %{event: event, payload: payload}}
    )
  end

  # Broadcast to both sortie and campaign topics (for sortie state changes)
  def broadcast_sortie_and_campaign_update(sortie_id, campaign_id, event, payload \\ %{}) do
    broadcast_sortie_update(sortie_id, event, payload)
    broadcast_campaign_update(campaign_id, event, payload)
  end
end
