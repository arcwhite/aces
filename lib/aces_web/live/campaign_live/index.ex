defmodule AcesWeb.CampaignLive.Index do
  @moduledoc """
  LiveView for displaying campaigns for the current user.
  Shows both active and past (completed/failed) campaigns in separate tabs.
  """
  use AcesWeb, :live_view

  alias Aces.{Campaigns, Companies}

  on_mount {AcesWeb.UserAuthLive, :default}

  # Tab definitions - hoisted here for discoverability
  @tabs [
    {"Active", :active},
    {"Past", :past}
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    # Get all campaigns for the user's companies
    all_campaigns = get_all_user_campaigns(user)

    # Separate into active and past campaigns
    {active_campaigns, past_campaigns} = Enum.split_with(all_campaigns, &(&1.status == "active"))

    {:ok,
     socket
     |> assign(:active_campaigns, active_campaigns)
     |> assign(:past_campaigns, past_campaigns)
     |> assign(:tabs, @tabs)
     |> assign(:selected_tab, :active)
     |> assign(:page_title, "My Campaigns")}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)
    {:noreply, assign(socket, :selected_tab, tab_atom)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 mb-6">
        <div>
          <h1 class="text-2xl sm:text-4xl font-bold">My Campaigns</h1>
          <p class="text-base-content/70 mt-2">
            Campaigns across all your companies
          </p>
        </div>
      </div>

      <.tab_navigation
        tabs={@tabs}
        active_tab={@selected_tab}
        on_change="select_tab"
        show_counts={tab_counts(@active_campaigns, @past_campaigns)}
        class="tabs tabs-bordered mb-6"
      />

      <%= if @selected_tab == :active do %>
        {render_campaigns_grid(assigns, @active_campaigns, :active)}
      <% else %>
        {render_campaigns_grid(assigns, @past_campaigns, :past)}
      <% end %>
    </div>
    """
  end

  defp render_campaigns_grid(assigns, campaigns, tab_type) do
    assigns = assign(assigns, campaigns: campaigns, tab_type: tab_type)

    ~H"""
    <%= if @campaigns == [] do %>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body text-center py-12">
          <%= if @tab_type == :active do %>
            <h2 class="card-title justify-center text-xl">No Active Campaigns</h2>
            <p class="text-base-content/70 mb-6">
              You don't have any active campaigns yet. Create a company and start your first campaign!
            </p>
            <.link href={~p"/companies"} class="btn btn-primary">
              Go to Companies
            </.link>
          <% else %>
            <h2 class="card-title justify-center text-xl">No Past Campaigns</h2>
            <p class="text-base-content/70">
              Completed and failed campaigns will appear here.
            </p>
          <% end %>
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

                <%= if @tab_type == :past && campaign.completed_at do %>
                  <div class="flex justify-between">
                    <span class="opacity-70">Completed:</span>
                    <span class="font-medium">{format_date(campaign.completed_at)}</span>
                  </div>
                <% end %>
              </div>

              <div class="card-actions justify-end mt-4">
                <.link
                  navigate={~p"/companies/#{campaign.company_id}/campaigns/#{campaign.id}"}
                  class="btn btn-primary btn-sm md:btn-xs"
                >
                  View Campaign
                </.link>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp get_all_user_campaigns(user) do
    # Get all companies for the user
    user_companies = Companies.list_user_companies(user)

    # Get all campaigns for those companies (active and past)
    company_ids = Enum.map(user_companies, & &1.id)

    Campaigns.list_campaigns_by_company_ids(company_ids)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  defp tab_counts(active_campaigns, past_campaigns) do
    counts = %{}
    counts = if active_campaigns != [], do: Map.put(counts, :active, length(active_campaigns)), else: counts
    counts = if past_campaigns != [], do: Map.put(counts, :past, length(past_campaigns)), else: counts
    counts
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
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