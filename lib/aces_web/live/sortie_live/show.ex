defmodule AcesWeb.SortieLive.Show do
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
  alias Aces.Companies.Authorization
  alias Aces.Campaigns.Deployment

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(%{"company_id" => company_id, "campaign_id" => campaign_id, "id" => sortie_id}, _session, socket) do
    company = Companies.get_company!(company_id)
    campaign = Campaigns.get_campaign!(campaign_id)
    sortie = Campaigns.get_sortie!(sortie_id)
    user = socket.assigns.current_scope.user

    unless Authorization.can?(:view_company, user, company) do
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view this company")
       |> redirect(to: ~p"/companies")}
    else
      # Verify campaign belongs to company and sortie belongs to campaign
      if campaign.company_id != company.id or sortie.campaign_id != campaign.id do
        {:ok,
         socket
         |> put_flash(:error, "Sortie not found")
         |> redirect(to: ~p"/companies/#{company_id}/campaigns/#{campaign_id}")}
      else
        # Get deployed pilots for force commander selection (only pilots deployed on this sortie)
        deployed_pilots =
          sortie.deployments
          |> Enum.filter(& &1.pilot_id)
          |> Enum.map(& &1.pilot)
          |> Enum.filter(& &1)

        # Default to first deployed pilot or existing force commander
        default_force_commander_id =
          cond do
            sortie.force_commander_id -> sortie.force_commander_id
            length(deployed_pilots) > 0 -> hd(deployed_pilots).id
            true -> nil
          end

        {:ok,
         socket
         |> assign(:company, company)
         |> assign(:campaign, campaign)
         |> assign(:sortie, sortie)
         |> assign(:deployed_pilots, deployed_pilots)
         |> assign(:selected_force_commander_id, default_force_commander_id)
         |> assign(:page_title, "Sortie #{sortie.mission_number}: #{sortie.name}")
         |> assign(:can_edit, Authorization.can?(:edit_company, user, company))}
      end
    end
  end

  @impl true
  def handle_event("update_damage_status", params, socket) do
    if socket.assigns.can_edit and socket.assigns.sortie.status == "in_progress" do
      # Extract deployment_id and damage_status from params
      # The form will send params like %{"damage_status_123" => "armor_damaged"}
      case params |> Enum.find_value(fn 
          {"damage_status_" <> id_string, status} -> {String.to_integer(id_string), status}
          _ -> nil
        end) do
        {deployment_id, damage_status} ->
          deployment = Enum.find(socket.assigns.sortie.deployments, &(&1.id == deployment_id))
          
          if deployment do
            case update_deployment_damage(deployment, damage_status) do
              {:ok, _updated_deployment} ->
                # Reload the sortie to get updated deployments
                updated_sortie = Campaigns.get_sortie!(socket.assigns.sortie.id)
                
                {:noreply,
                 socket
                 |> assign(:sortie, updated_sortie)
                 |> put_flash(:info, "Unit damage updated")}

              {:error, _changeset} ->
                {:noreply,
                 socket
                 |> put_flash(:error, "Failed to update damage status")}
            end
          else
            {:noreply,
             socket
             |> put_flash(:error, "Deployment not found")}
          end
        
        nil ->
          {:noreply,
           socket
           |> put_flash(:error, "Invalid damage status parameters")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Cannot update damage - sortie is not in progress or you lack permissions")}
    end
  end

  @impl true
  def handle_event("select_force_commander", %{"force_commander_id" => force_commander_id}, socket) do
    force_commander_id_int =
      case force_commander_id do
        "" -> nil
        id -> String.to_integer(id)
      end

    {:noreply, assign(socket, :selected_force_commander_id, force_commander_id_int)}
  end

  @impl true
  def handle_event("start_sortie", _params, socket) do
    if socket.assigns.can_edit and socket.assigns.sortie.status == "setup" do
      force_commander_id = socket.assigns.selected_force_commander_id

      if is_nil(force_commander_id) do
        {:noreply,
         socket
         |> put_flash(:error, "Please select a Force Commander")}
      else
        # Validate that the selected force commander is deployed on this sortie
        deployed_pilot_ids =
          socket.assigns.sortie.deployments
          |> Enum.filter(& &1.pilot_id)
          |> Enum.map(& &1.pilot_id)

        unless force_commander_id in deployed_pilot_ids do
          {:noreply,
           socket
           |> put_flash(:error, "Force Commander must be one of the deployed pilots")}
        else
          # Reload campaign to get current sortie statuses
          campaign = Campaigns.get_campaign!(socket.assigns.campaign.id)
          in_progress_sorties = Enum.filter(campaign.sorties, &(&1.status == "in_progress"))

          if length(in_progress_sorties) > 0 do
            {:noreply,
             socket
             |> put_flash(:error, "Only one sortie can be in progress at a time. Complete the current sortie before starting a new one.")}
          else
            case Campaigns.start_sortie(socket.assigns.sortie, force_commander_id) do
              {:ok, updated_sortie} ->
                {:noreply,
                 socket
                 |> assign(:sortie, updated_sortie)
                 |> put_flash(:info, "Sortie started successfully!")}

              {:error, %Ecto.Changeset{} = changeset} ->
                error_message = format_changeset_errors(changeset)

                {:noreply,
                 socket
                 |> put_flash(:error, "Cannot start sortie: #{error_message}")}
            end
          end
        end
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Cannot start sortie - not in setup state or insufficient permissions")}
    end
  end

  @impl true
  def handle_event("update_pilot_casualty", params, socket) do
    if socket.assigns.can_edit and socket.assigns.sortie.status == "in_progress" do
      # Extract deployment_id and pilot_casualty from params
      # The form will send params like %{"pilot_casualty_123" => "wounded"}
      case params |> Enum.find_value(fn 
          {"pilot_casualty_" <> id_string, status} -> {String.to_integer(id_string), status}
          _ -> nil
        end) do
        {deployment_id, casualty_status} ->
          deployment = Enum.find(socket.assigns.sortie.deployments, &(&1.id == deployment_id))
          
          if deployment do
            case update_deployment_casualty(deployment, casualty_status) do
              {:ok, _updated_deployment} ->
                # Reload the sortie to get updated deployments
                updated_sortie = Campaigns.get_sortie!(socket.assigns.sortie.id)
                
                casualty_type = if deployment.pilot_id, do: "Pilot", else: "Crew"
                
                {:noreply,
                 socket
                 |> assign(:sortie, updated_sortie)
                 |> put_flash(:info, "#{casualty_type} casualty updated")}

              {:error, _changeset} ->
                {:noreply,
                 socket
                 |> put_flash(:error, "Failed to update casualty status")}
            end
          else
            {:noreply,
             socket
             |> put_flash(:error, "Deployment not found")}
          end
        
        nil ->
          {:noreply,
           socket
           |> put_flash(:error, "Invalid pilot casualty parameters")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Cannot update casualty - sortie is not in progress or you lack permissions")}
    end
  end

  defp update_deployment_damage(deployment, damage_status) do
    deployment
    |> Deployment.changeset(%{damage_status: damage_status})
    |> Aces.Repo.update()
  end

  defp update_deployment_casualty(deployment, pilot_casualty) do
    deployment
    |> Deployment.changeset(%{pilot_casualty: pilot_casualty})
    |> Aces.Repo.update()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <.link navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}"} class="btn btn-ghost btn-sm">
            ← Back to {@campaign.name}
          </.link>
        </div>

        <div class="flex justify-between items-start mb-4">
          <div>
            <h1 class="text-4xl font-bold mb-2">Sortie #{@sortie.mission_number}: {@sortie.name}</h1>
            <%= if @sortie.description do %>
              <p class="text-lg opacity-70">{@sortie.description}</p>
            <% end %>
          </div>
          
          <div class="flex items-center gap-2">
            <div class={[
              "badge badge-lg",
              @sortie.status == "setup" && "badge-neutral",
              @sortie.status == "in_progress" && "badge-warning",
              @sortie.status == "success" && "badge-success",
              @sortie.status == "failed" && "badge-error",
              @sortie.status == "completed" && "badge-info"
            ]}>
              {String.capitalize(@sortie.status)}
            </div>
          </div>
        </div>
      </div>

      <!-- Sortie Details -->
      <div class="grid gap-6 md:grid-cols-3 mb-8">
        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">PV Limit</div>
          <div class="stat-value text-primary">{@sortie.pv_limit}</div>
          <div class="stat-desc">Point Value limit</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Deployed PV</div>
          <div class="stat-value text-secondary">{Aces.Campaigns.calculate_deployed_pv(@sortie)}</div>
          <div class="stat-desc">Currently deployed</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow">
          <div class="stat-title">Force Commander</div>
          <div class="stat-value text-accent">
            <%= if @sortie.force_commander do %>
              {@sortie.force_commander.name}
            <% else %>
              TBD
            <% end %>
          </div>
          <div class="stat-desc">Mission leader</div>
        </div>
      </div>

      <!-- Deployment Status -->
      <div class="mb-8">
        <h2 class="text-2xl font-bold mb-4">Deployment Status</h2>
        
        <%= if length(@sortie.deployments) == 0 do %>
          <div class="alert alert-warning">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.732-.833-2.502 0L4.232 15.5c-.77.833.192 2.5 1.732 2.5z"></path>
            </svg>
            <span>No units deployed yet.</span>
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-zebra w-full">
              <thead>
                <tr>
                  <th>Unit</th>
                  <th>Pilot</th>
                  <th>PV</th>
                  <th>Damage Status</th>
                  <th>Pilot Status</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for deployment <- @sortie.deployments do %>
                  <tr>
                    <td>
                      <div class="font-semibold">
                        {deployment.company_unit.custom_name || deployment.company_unit.master_unit.name}
                      </div>
                      <div class="text-sm opacity-70">
                        {deployment.company_unit.master_unit.variant}
                      </div>
                    </td>
                    <td>
                      <%= if deployment.pilot do %>
                        <div class="font-semibold">{deployment.pilot.name}</div>
                        <div class="text-sm opacity-70">Skill {deployment.pilot.skill_level}</div>
                      <% else %>
                        <div class="text-sm opacity-70">Unnamed crew</div>
                      <% end %>
                    </td>
                    <td class="font-mono">{deployment.company_unit.master_unit.point_value} PV</td>
                    <td>
                      <%= if @sortie.status == "in_progress" and @can_edit do %>
                        <form phx-change="update_damage_status" id={"damage-form-#{deployment.id}"}>
                          <select 
                            class={[
                              "select select-sm w-full max-w-xs",
                              damage_status_color(deployment.damage_status)
                            ]}
                            name={"damage_status_#{deployment.id}"}
                          >
                            <option value="operational" selected={deployment.damage_status == "operational"}>Operational</option>
                            <option value="armor_damaged" selected={deployment.damage_status == "armor_damaged"}>Armor Damage</option>
                            <option value="structure_damaged" selected={deployment.damage_status == "structure_damaged"}>Structure Damage</option>
                            <option value="crippled" selected={deployment.damage_status == "crippled"}>Crippled</option>
                            <option value="destroyed" selected={deployment.damage_status == "destroyed"}>Destroyed</option>
                          </select>
                        </form>
                      <% else %>
                        <div class={[
                          "badge",
                          damage_status_color(deployment.damage_status)
                        ]}>
                          {format_damage_status(deployment.damage_status)}
                        </div>
                      <% end %>
                    </td>
                    <td>
                      <%= if @sortie.status == "in_progress" and @can_edit do %>
                        <form phx-change="update_pilot_casualty" id={"casualty-form-#{deployment.id}"}>
                          <select 
                            class={[
                              "select select-sm w-full max-w-xs",
                              casualty_status_color(deployment.pilot_casualty)
                            ]}
                            name={"pilot_casualty_#{deployment.id}"}
                          >
                            <option value="none" selected={deployment.pilot_casualty == "none"}>Unharmed</option>
                            <option value="wounded" selected={deployment.pilot_casualty == "wounded"}>Wounded</option>
                            <option value="killed" selected={deployment.pilot_casualty == "killed"}>Killed</option>
                          </select>
                        </form>
                        <%= if is_nil(deployment.pilot) do %>
                          <div class="text-xs text-gray-500 mt-1">Crew casualty: 100 SP cost</div>
                        <% end %>
                      <% else %>
                        <div class={[
                          "badge",
                          casualty_status_color(deployment.pilot_casualty)
                        ]}>
                          {format_casualty_status(deployment.pilot_casualty)}
                        </div>
                        <%= if is_nil(deployment.pilot) and deployment.pilot_casualty != "none" do %>
                          <div class="text-xs text-gray-500 mt-1">Crew casualty: 100 SP cost</div>
                        <% end %>
                      <% end %>
                    </td>
                    <td>
                      <div class="text-sm opacity-70">
                        Damage tracking live
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>

      <!-- Mission Status -->
      <%= if @sortie.status == "setup" and @can_edit do %>
        <div class="card bg-base-100 shadow-xl mb-8">
          <div class="card-body">
            <h3 class="card-title">Start Sortie</h3>
            <p class="text-sm opacity-70 mb-4">
              Before starting the sortie, select a Force Commander and ensure you have deployed units.
            </p>
            
            <%= if length(@deployed_pilots) == 0 do %>
              <div class="alert alert-warning mb-4">
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.732-.833-2.502 0L4.232 15.5c-.77.833.192 2.5 1.732 2.5z"></path>
                </svg>
                <span>No pilots deployed. Deploy at least one unit with a named pilot to start the sortie.</span>
              </div>
            <% end %>

            <div class="form-control mb-4">
              <label class="label">
                <span class="label-text">Force Commander</span>
              </label>
              <%= if length(@deployed_pilots) > 0 do %>
                <select
                  name="force_commander_id"
                  class="select select-bordered w-full"
                  phx-change="select_force_commander"
                >
                  <%= for pilot <- @deployed_pilots do %>
                    <option value={pilot.id} selected={pilot.id == @selected_force_commander_id}>
                      {pilot.name} ({pilot.callsign})
                    </option>
                  <% end %>
                </select>
              <% else %>
                <select class="select select-bordered w-full" disabled>
                  <option>No deployed pilots available</option>
                </select>
              <% end %>
            </div>

            <div class="card-actions justify-end">
              <button
                class="btn btn-primary"
                phx-click="start_sortie"
                disabled={length(@deployed_pilots) == 0 or is_nil(@selected_force_commander_id)}
              >
                Start Sortie
              </button>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @sortie.status == "setup" and not @can_edit do %>
        <div class="alert alert-info mb-8">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
          </svg>
          <span>Sortie is in setup phase. Waiting for deployment and force commander assignment.</span>
        </div>
      <% end %>

      <%= if @sortie.status == "in_progress" do %>
        <div class="alert alert-info mb-8">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
          </svg>
          <span>Mission in progress. Mark unit damage and pilot casualties as they occur during play.</span>
        </div>
      <% end %>

      <!-- Reconnaissance Options (if configured) -->
      <%= if @sortie.recon_options && length(@sortie.recon_options) > 0 do %>
        <div class="mb-8">
          <h3 class="text-xl font-semibold mb-4">Reconnaissance Options</h3>
          <div class="space-y-2">
            <%= for recon <- @sortie.recon_options do %>
              <div class="card bg-base-200 p-4">
                <div class="flex justify-between items-center">
                  <div>
                    <div class="font-semibold">{recon["name"]}</div>
                    <div class="text-sm opacity-70">{recon["description"]}</div>
                  </div>
                  <div class="badge badge-outline">{recon["cost_sp"]} SP</div>
                </div>
              </div>
            <% end %>
            <div class="text-sm font-semibold">
              Total Reconnaissance Cost: {Enum.sum(Enum.map(@sortie.recon_options, &Map.get(&1, "cost_sp", 0)))} SP
            </div>
          </div>
        </div>
      <% end %>

      <!-- Notes -->
      <%= if @sortie.recon_notes && String.trim(@sortie.recon_notes) != "" do %>
        <div class="mb-8">
          <h3 class="text-xl font-semibold mb-4">Mission Notes</h3>
          <div class="card bg-base-200 p-4">
            <p class="whitespace-pre-wrap">{@sortie.recon_notes}</p>
          </div>
        </div>
      <% end %>

      <!-- Mission Dates -->
      <div class="text-sm text-gray-600 mt-8 border-t pt-4">
        <div class="flex justify-between">
          <div>
            <%= if @sortie.started_at do %>
              Started: {Calendar.strftime(@sortie.started_at, "%B %d, %Y at %I:%M %p")}
            <% else %>
              Not started yet
            <% end %>
          </div>
          <%= if @sortie.completed_at do %>
            <div>
              Completed: {Calendar.strftime(@sortie.completed_at, "%B %d, %Y at %I:%M %p")}
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions for styling
  defp damage_status_color(status) do
    case status do
      "operational" -> "select-success"
      "armor_damaged" -> "select-warning"
      "structure_damaged" -> "select-warning"
      "crippled" -> "select-error"
      "destroyed" -> "select-error"
      _ -> ""
    end
  end

  defp casualty_status_color(status) do
    case status do
      "none" -> "select-success"
      "wounded" -> "select-warning"
      "killed" -> "select-error"
      _ -> ""
    end
  end

  defp format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
    |> Enum.join(", ")
  end

  defp format_damage_status(status) do
    case status do
      "operational" -> "Operational"
      "armor_damaged" -> "Armor Damage"
      "structure_damaged" -> "Structure Damage"
      "crippled" -> "Crippled"
      "destroyed" -> "Destroyed"
      _ -> String.capitalize(status || "unknown")
    end
  end

  defp format_casualty_status(status) do
    case status do
      "none" -> "Unharmed"
      "wounded" -> "Wounded"
      "killed" -> "Killed"
      _ -> String.capitalize(status || "unknown")
    end
  end
end