defmodule AcesWeb.CampaignLive.Index do
  @moduledoc """
  LiveView for displaying all active campaigns for the current user
  """
  use AcesWeb, :live_view

  alias Aces.{Campaigns, Companies}

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    
    # Get all campaigns for the user's companies
    campaigns = get_user_campaigns(user)
    
    {:ok,
     socket
     |> assign(:campaigns, campaigns)
     |> assign(:page_title, "My Campaigns")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-3xl font-bold">My Campaigns</h1>
          <p class="text-base-content/70 mt-2">
            Active campaigns across all your companies
          </p>
        </div>
        
        <.link
          patch={~p"/companies"}
          class="btn btn-ghost"
        >
          ← Back to Companies
        </.link>
      </div>

      <%= if @campaigns == [] do %>
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body text-center py-12">
            <h2 class="card-title justify-center text-xl">No Active Campaigns</h2>
            <p class="text-base-content/70 mb-6">
              You don't have any active campaigns yet. Create a company and start your first campaign!
            </p>
            <.link href={~p"/companies"} class="btn btn-primary">
              Go to Companies
            </.link>
          </div>
        </div>
      <% else %>
        <div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
          <%= for campaign <- @campaigns do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">
                  {campaign.name}
                  <div class={"badge badge-sm " <> difficulty_badge_class(campaign.difficulty_level)}>
                    {String.capitalize(campaign.difficulty_level)}
                  </div>
                </h2>
                
                <p class="text-sm text-base-content/70 mb-4">
                  {campaign.description || "No description"}
                </p>
                
                <div class="space-y-2 text-sm">
                  <div class="flex justify-between">
                    <span class="opacity-70">Company:</span>
                    <span class="font-medium">{campaign.company.name}</span>
                  </div>
                  
                  <div class="flex justify-between">
                    <span class="opacity-70">Status:</span>
                    <div class={"badge badge-sm " <> status_badge_class(campaign.status)}>
                      {String.capitalize(campaign.status)}
                    </div>
                  </div>
                  
                  <div class="flex justify-between">
                    <span class="opacity-70">Warchest:</span>
                    <span class="font-medium">{campaign.warchest_balance} SP</span>
                  </div>
                  
                  <div class="flex justify-between">
                    <span class="opacity-70">Sorties:</span>
                    <span class="font-medium">{length(campaign.sorties || [])}</span>
                  </div>
                </div>
                
                <div class="card-actions justify-end mt-4">
                  <.link
                    navigate={~p"/companies/#{campaign.company_id}/campaigns/#{campaign.id}"}
                    class="btn btn-primary btn-sm"
                  >
                    View Campaign
                  </.link>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp get_user_campaigns(user) do
    # Get all companies for the user
    user_companies = Companies.list_user_companies(user)
    
    # Get all active campaigns for those companies
    company_ids = Enum.map(user_companies, & &1.id)
    
    Campaigns.list_campaigns_by_company_ids(company_ids)
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  defp difficulty_badge_class("recruit"), do: "badge-success"
  defp difficulty_badge_class("regular"), do: "badge-info"
  defp difficulty_badge_class("veteran"), do: "badge-warning"
  defp difficulty_badge_class("elite"), do: "badge-error"
  defp difficulty_badge_class("legendary"), do: "badge-error"
  defp difficulty_badge_class(_), do: "badge-ghost"

  defp status_badge_class("active"), do: "badge-success"
  defp status_badge_class("completed"), do: "badge-info"
  defp status_badge_class("failed"), do: "badge-error"
  defp status_badge_class(_), do: "badge-ghost"
end