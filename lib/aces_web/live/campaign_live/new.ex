defmodule AcesWeb.CampaignLive.New do
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
  alias Aces.Companies.{Authorization, Campaign}

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(%{"company_id" => company_id}, _session, socket) do
    company = Companies.get_company!(company_id)
    user = socket.assigns.current_scope.user

    unless Authorization.can?(:edit_company, user, company) do
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to create campaigns for this company")
       |> redirect(to: ~p"/companies")}
    else
      # Check if company already has an active campaign
      case Campaigns.get_active_campaign(company) do
        nil ->
          {:ok,
           socket
           |> assign(:company, company)
           |> assign(:page_title, "Start New Campaign")
           |> assign_form(Campaign.creation_changeset(%Campaign{}, %{}))}

        _active_campaign ->
          {:ok,
           socket
           |> put_flash(:error, "Company already has an active campaign")
           |> redirect(to: ~p"/companies/#{company_id}")}
      end
    end
  end

  @impl true
  def handle_event("validate", %{"campaign" => campaign_params}, socket) do
    changeset =
      %Campaign{}
      |> Campaign.creation_changeset(campaign_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"campaign" => campaign_params}, socket) do
    company = socket.assigns.company

    case Campaigns.create_campaign(company, campaign_params) do
      {:ok, campaign} ->
        {:noreply,
         socket
         |> put_flash(:info, "Campaign '#{campaign.name}' started successfully!")
         |> redirect(to: ~p"/companies/#{company.id}/campaigns/#{campaign.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <.link navigate={~p"/companies/#{@company.id}"} class="btn btn-ghost btn-sm">
            ← Back to {@company.name}
          </.link>
        </div>

        <h1 class="text-4xl font-bold mb-2">Start New Campaign</h1>
        <p class="text-lg opacity-70">Deploy your mercenary company on a new campaign</p>
      </div>

      <div class="grid gap-8 lg:grid-cols-3">
        <!-- Campaign Creation Form -->
        <div class="lg:col-span-2">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title mb-4">Campaign Details</h2>
              
              <.form 
                for={@form} 
                id="campaign-form" 
                phx-change="validate" 
                phx-submit="save"
                class="space-y-6"
              >
                <.input 
                  field={@form[:name]} 
                  type="text" 
                  label="Campaign Name"
                  placeholder="e.g., Operation: Steel Rain"
                  required
                />

                <.input 
                  field={@form[:description]} 
                  type="textarea" 
                  label="Description (Optional)"
                  placeholder="Describe your campaign's mission, location, or background..."
                  rows="3"
                />

                <.input 
                  field={@form[:difficulty_level]} 
                  type="select" 
                  label="Difficulty Level"
                  options={[
                    {"Rookie (20% easier, 20% more rewards)", "rookie"},
                    {"Standard (balanced)", "standard"}, 
                    {"Veteran (10% harder, 10% less rewards)", "veteran"},
                    {"Elite (20% harder, 20% less rewards)", "elite"},
                    {"Legendary (30% harder, 30% less rewards)", "legendary"}
                  ]}
                  required
                />

                <div>
                  <.input 
                    field={@form[:warchest_balance]} 
                    type="number" 
                    label="Starting Warchest (SP)"
                    min="0" 
                    value={@company.warchest_balance}
                    required
                  />
                  <div class="text-sm text-gray-600 mt-1">
                    Current company warchest: {@company.warchest_balance} SP
                  </div>
                </div>


                <div class="card-actions justify-end pt-4">
                  <.link 
                    patch={~p"/companies/#{@company.id}"} 
                    class="btn btn-ghost"
                  >
                    Cancel
                  </.link>
                  
                  <button 
                    type="submit" 
                    class="btn btn-primary"
                  >
                    Start Campaign
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <!-- Company Summary -->
        <div class="lg:col-span-1">
          <div class="card bg-base-200 shadow-xl sticky top-8">
            <div class="card-body">
              <h3 class="card-title">Company Summary</h3>
              
              <div class="stats stats-vertical">
                <div class="stat">
                  <div class="stat-title">Company</div>
                  <div class="stat-value text-lg">{@company.name}</div>
                </div>
                
                <div class="stat">
                  <div class="stat-title">Total Units</div>
                  <div class="stat-value text-primary">{length(@company.company_units)}</div>
                </div>
                
                <div class="stat">
                  <div class="stat-title">Pilots</div>
                  <div class="stat-value text-info">{length(@company.pilots)}</div>
                </div>
                
                <div class="stat">
                  <div class="stat-title">Current Warchest</div>
                  <div class="stat-value text-secondary">{@company.warchest_balance} SP</div>
                </div>
              </div>

              <div class="alert alert-info mt-4">
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <div class="text-sm">
                  <p class="font-semibold">Campaign Setup</p>
                  <p>Starting a campaign will lock your current warchest balance as the campaign starting funds.</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end