defmodule AcesWeb.SortieLive.New do
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns, ChangesetHelpers}
  alias Aces.Companies.Authorization
  alias Aces.Campaigns.Sortie

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(%{"company_id" => company_id, "campaign_id" => campaign_id}, _session, socket) do
    company = Companies.get_company!(company_id)
    campaign = Campaigns.get_campaign!(campaign_id)
    user = socket.assigns.current_scope.user

    unless Authorization.can?(:edit_company, user, company) do
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to create sorties for this campaign")
       |> redirect(to: ~p"/companies")}
    else
      # Verify campaign belongs to company
      if campaign.company_id != company.id do
        {:ok,
         socket
         |> put_flash(:error, "Campaign not found")
         |> redirect(to: ~p"/companies/#{company_id}")}
      else
        # Get available units (not destroyed/sold) for deployment
        available_units = get_available_units(company)
        available_pilots = get_available_pilots(company)

        {:ok,
         socket
         |> assign(:campaign, campaign)
         |> assign(:available_units, available_units)
         |> assign(:available_pilots, available_pilots)
         |> assign(:selected_deployments, [])
         |> assign(:pv_limit, nil)
         |> assign(:page_title, "Create New Sortie")
         |> assign_form(Sortie.creation_changeset(%Sortie{}, %{"campaign_id" => campaign.id}))
        }
      end
    end
  end

  @impl true
  def handle_event("validate", %{"sortie" => sortie_params}, socket) do
    # Add campaign_id to params for validation
    params_with_campaign = Map.put(sortie_params, "campaign_id", socket.assigns.campaign.id)

    changeset =
      %Sortie{}
      |> Sortie.creation_changeset(params_with_campaign)
      |> Map.put(:action, :validate)

    # Track the current PV limit for deployment validation
    pv_limit = parse_pv_limit(sortie_params["pv_limit"])

    {:noreply,
     socket
     |> assign(:pv_limit, pv_limit)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"sortie" => sortie_params}, socket) do
    campaign = socket.assigns.campaign

    # Add campaign_id to params
    params_with_campaign = Map.put(sortie_params, "campaign_id", campaign.id)

    # Create sortie first, then handle deployments
    case Campaigns.create_sortie(campaign, params_with_campaign) do
      {:ok, sortie} ->
        # Create deployments for selected units
        case create_deployments(sortie, socket.assigns.selected_deployments) do
          {:ok, _deployments} ->
            {:noreply,
             socket
             |> put_flash(:info, "Sortie '#{sortie.name}' created successfully!")
             |> redirect(to: ~p"/companies/#{campaign.company_id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to create deployments: #{inspect(reason)}")}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        # Extract error message for flash
        error_message = ChangesetHelpers.format_errors(changeset)

        {:noreply,
         socket
         |> put_flash(:error, "Failed to create sortie: #{error_message}")
         |> assign_form(changeset)}
    end
  end

  def handle_event("toggle_unit_deployment", %{"unit_id" => unit_id}, socket) do
    unit_id = String.to_integer(unit_id)
    selected_deployments = socket.assigns.selected_deployments
    pv_limit = socket.assigns.pv_limit
    available_units = socket.assigns.available_units

    is_currently_deployed = Enum.any?(selected_deployments, &(&1.company_unit_id == unit_id))

    if is_currently_deployed do
      # Remove deployment - always allowed
      updated_deployments = Enum.reject(selected_deployments, &(&1.company_unit_id == unit_id))
      {:noreply, assign(socket, :selected_deployments, updated_deployments)}
    else
      # Add deployment - check PV limit first
      unit = Enum.find(available_units, &(&1.id == unit_id))

      if unit do
        unit_pv = unit.master_unit.point_value || 0
        current_total_pv = calculate_total_pv(selected_deployments, available_units)
        new_total_pv = current_total_pv + unit_pv

        if pv_limit && new_total_pv > pv_limit do
          # Would exceed PV limit - show error
          {:noreply,
           socket
           |> put_flash(:error, "Cannot add #{unit.custom_name || unit.master_unit.name} (#{unit_pv} PV) - would exceed PV limit of #{pv_limit}. Current: #{current_total_pv} PV.")}
        else
          new_deployment = %{
            company_unit_id: unit_id,
            pilot_id: nil,
            unit: unit
          }
          {:noreply, assign(socket, :selected_deployments, [new_deployment | selected_deployments])}
        end
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("assign_pilot", %{"unit_id" => unit_id_str, "value" => pilot_value}, socket) do
    unit_id = String.to_integer(unit_id_str)
    pilot_id = case pilot_value do
      "" -> nil
      value when is_binary(value) -> String.to_integer(value)
      _ -> nil
    end


    # If assigning a pilot, first remove that pilot from any other units
    deployments_without_pilot = if pilot_id do
      Enum.map(socket.assigns.selected_deployments, fn deployment ->
        if deployment.pilot_id == pilot_id and deployment.company_unit_id != unit_id do
          %{deployment | pilot_id: nil}  # Remove pilot from other units
        else
          deployment
        end
      end)
    else
      socket.assigns.selected_deployments
    end

    # Now assign the pilot to the target unit
    updated_deployments =
      Enum.map(deployments_without_pilot, fn deployment ->
        if deployment.company_unit_id == unit_id do
          %{deployment | pilot_id: pilot_id}
        else
          deployment
        end
      end)


    {:noreply, assign(socket, :selected_deployments, updated_deployments)}
  end

  def handle_event("assign_pilot", _params, socket) do
    # Fallback for malformed events
    {:noreply, socket}
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp get_available_units(company) do
    company.company_units
    |> Enum.filter(&(&1.status == "operational"))
    |> Enum.sort_by(&(&1.custom_name || &1.master_unit.name))
  end

  defp get_available_pilots(company) do
    company.pilots
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.sort_by(& &1.callsign)
  end

  defp get_assignable_pilots(available_pilots, selected_deployments, current_unit_id) do
    # Get IDs of pilots already assigned to OTHER units (not the current one)
    assigned_pilot_ids = 
      selected_deployments
      |> Enum.filter(&(&1.pilot_id && &1.company_unit_id != current_unit_id))
      |> Enum.map(& &1.pilot_id)

    # Filter out pilots that are already assigned to other units
    available_pilots
    |> Enum.reject(&(&1.id in assigned_pilot_ids))
  end

  defp create_deployments(_sortie, []), do: {:ok, []}
  defp create_deployments(sortie, deployments) do
    results = 
      Enum.map(deployments, fn deployment ->
        Campaigns.create_deployment(sortie, deployment)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, dep} -> dep end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp calculate_total_pv(deployments, available_units) do
    deployments
    |> Enum.map(fn deployment ->
      unit = Enum.find(available_units, &(&1.id == deployment.company_unit_id))
      if unit && unit.master_unit do
        unit.master_unit.point_value || 0
      else
        0
      end
    end)
    |> Enum.sum()
  end

  defp parse_pv_limit(nil), do: nil
  defp parse_pv_limit(""), do: nil
  defp parse_pv_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> nil
    end
  end
  defp parse_pv_limit(value) when is_integer(value) and value > 0, do: value
  defp parse_pv_limit(_), do: nil

  defp pv_over_limit?(deployments, available_units, pv_limit) do
    pv_limit != nil and calculate_total_pv(deployments, available_units) > pv_limit
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <.link navigate={~p"/companies/#{@campaign.company_id}/campaigns/#{@campaign.id}"} class="btn btn-ghost btn-sm">
            ← Back to Campaign
          </.link>
        </div>

        <h1 class="text-4xl font-bold mb-2">Create New Sortie</h1>
        <p class="text-lg opacity-70">New mission for {@campaign.name}</p>
      </div>

      <div class="grid gap-8 lg:grid-cols-3">
        <!-- Sortie Creation Form -->
        <div class="lg:col-span-2">
          <.form 
            for={@form} 
            id="sortie-form" 
            phx-change="validate" 
            phx-submit="save"
            class="space-y-8"
          >
            <!-- Mission Details -->
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title mb-4">Mission Details</h2>
                
                <div class="space-y-4">
                  <.input 
                    field={@form[:mission_number]} 
                    type="text" 
                    label="Mission Number"
                    placeholder="e.g., 1, 2A, 3B"
                    required
                  />

                  <.input 
                    field={@form[:name]} 
                    type="text" 
                    label="Mission Name"
                    placeholder="e.g., Assault on Garrison Alpha"
                    required
                  />

                  <.input 
                    field={@form[:description]} 
                    type="textarea" 
                    label="Mission Description (Optional)"
                    placeholder="Describe the mission objectives, terrain, or special conditions..."
                    rows="3"
                  />

                  <.input 
                    field={@form[:pv_limit]} 
                    type="number" 
                    label="Point Value Limit"
                    min="1" 
                    placeholder="e.g., 200"
                    required
                  />
                </div>
              </div>
            </div>

            <!-- Unit Deployment -->
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title mb-4">Unit Deployment</h2>
                
                <div class="space-y-4">
                  <p class="text-sm opacity-70">Select which units to deploy and assign pilots</p>
                  
                  <div class="grid gap-4 md:grid-cols-2">
                    <%= for unit <- @available_units do %>
                      <% deployment = Enum.find(@selected_deployments, fn d -> d.company_unit_id == unit.id end) %>
                      <% is_deployed = !is_nil(deployment) %>
                      <% current_pilot_id = if deployment, do: deployment.pilot_id, else: nil %>
                      
                      <div class={"card border-2 transition-colors #{if is_deployed, do: "border-primary bg-primary/5", else: "border-base-300"}"}>
                        <div class="card-body p-4">
                          <div class="flex items-start justify-between">
                            <div class="flex-1">
                              <h3 class="font-semibold">{unit.custom_name || unit.master_unit.name}</h3>
                              <p class="text-sm opacity-70">
                                {unit.master_unit.name} ({unit.master_unit.point_value} PV)
                              </p>
                              <div class="flex gap-2 mt-2">
                                <div class={"badge badge-sm #{if unit.status == "operational", do: "badge-success", else: "badge-warning"}"}>
                                  {unit.status}
                                </div>
                                <%= if current_pilot_id do %>
                                  <% pilot = Enum.find(@available_pilots, &(&1.id == current_pilot_id)) %>
                                  <%= if pilot do %>
                                    <div class="badge badge-sm badge-info">{pilot.callsign}</div>
                                  <% end %>
                                <% end %>
                              </div>
                            </div>
                            
                            <input 
                              type="checkbox" 
                              class="checkbox checkbox-primary" 
                              checked={is_deployed}
                              phx-click="toggle_unit_deployment"
                              phx-value-unit_id={unit.id}
                            />
                          </div>
                          
                          <%= if is_deployed do %>
                            <div class="mt-4">
                              <select 
                                class="select select-sm select-bordered w-full"
                                phx-blur="assign_pilot"
                                phx-value-unit_id={unit.id}
                                value={current_pilot_id || ""}
                              >
                                <option value="">Unnamed Crew (Skill 4)</option>
                                <%= for pilot <- get_assignable_pilots(@available_pilots, @selected_deployments, unit.id) do %>
                                  <option value={pilot.id} selected={pilot.id == current_pilot_id}>
                                    {pilot.callsign} (Skill {pilot.skill_level})
                                  </option>
                                <% end %>
                              </select>
                            </div>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>

                  <%= if @selected_deployments == [] do %>
                    <div class="alert alert-warning">
                      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16c-.77.833.192 2.5 1.732 2.5z"></path>
                      </svg>
                      <span>Select at least one unit to deploy</span>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>

            <!-- Reconnaissance Options -->
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title mb-4">Reconnaissance Options</h2>
                
                <div class="space-y-4">
                  <p class="text-sm opacity-70">Select recon options to gather intelligence (costs SP)</p>
                  
                  <.input 
                    field={@form[:recon_notes]} 
                    type="textarea" 
                    label="Reconnaissance Notes (Optional)"
                    placeholder="List recon options purchased..."
                    rows="3"
                  />

                  <.input 
                    field={@form[:recon_total_cost]} 
                    type="number" 
                    label="Total Reconnaissance Cost (SP)"
                    placeholder="0"
                    min="0"
                    value="0"
                  />
                  
                  <div class="text-sm opacity-70">
                    <p>Common recon options:</p>
                    <ul class="list-disc list-inside mt-1 space-y-1">
                      <li>Terrain Analysis - 10 SP</li>
                      <li>Enemy Force Composition - 15 SP</li>
                      <li>Objective Details - 20 SP</li>
                    </ul>
                  </div>
                </div>
              </div>
            </div>

            <!-- Form Actions -->
            <div class="flex justify-end gap-4">
              <.link 
                patch={~p"/companies/#{@campaign.company_id}/campaigns/#{@campaign.id}"} 
                class="btn btn-ghost"
              >
                Cancel
              </.link>
              
              <button
                type="submit"
                class="btn btn-primary"
                disabled={@selected_deployments == [] || !@form.source.valid? || pv_over_limit?(@selected_deployments, @available_units, @pv_limit)}
              >
                Create Sortie
              </button>
            </div>
          </.form>
        </div>

        <!-- Deployment Summary -->
        <div class="lg:col-span-1">
          <div class="card bg-base-200 shadow-xl sticky top-8">
            <div class="card-body">
              <h3 class="card-title">Deployment Summary</h3>
              
              <div class="stats stats-vertical">
                <div class="stat">
                  <div class="stat-title">Campaign</div>
                  <div class="stat-value text-lg">{@campaign.name}</div>
                </div>
                
                <div class="stat">
                  <div class="stat-title">Units Deployed</div>
                  <div class="stat-value text-primary">{length(@selected_deployments)}</div>
                </div>
                
                <div class="stat">
                  <div class="stat-title">Total PV</div>
                  <% total_pv = calculate_total_pv(@selected_deployments, @available_units) %>
                  <% over_limit = pv_over_limit?(@selected_deployments, @available_units, @pv_limit) %>
                  <div class={["stat-value", if(over_limit, do: "text-error", else: "text-info")]}>
                    {total_pv}<%= if @pv_limit do %>/{@pv_limit}<% end %>
                  </div>
                  <%= if over_limit do %>
                    <div class="stat-desc text-error">Exceeds PV limit!</div>
                  <% end %>
                </div>

                <div class="stat">
                  <div class="stat-title">Named Pilots</div>
                  <div class="stat-value text-secondary">
                    {Enum.count(@selected_deployments, & &1.pilot_id)}
                  </div>
                </div>
              </div>

              <%= if @selected_deployments != [] do %>
                <div class="mt-4">
                  <h4 class="font-semibold mb-2">Deployed Units:</h4>
                  <div class="space-y-2">
                    <%= for deployment <- @selected_deployments do %>
                      <% unit = Enum.find(@available_units, &(&1.id == deployment.company_unit_id)) %>
                      <% pilot = if deployment.pilot_id, do: Enum.find(@available_pilots, &(&1.id == deployment.pilot_id)), else: nil %>
                      
                      <div class="flex justify-between items-center p-2 bg-base-100 rounded">
                        <div>
                          <div class="font-medium text-sm">{unit.custom_name || unit.master_unit.name}</div>
                          <div class="text-xs opacity-70">
                            {if pilot, do: pilot.callsign, else: "Unnamed Crew"}
                          </div>
                        </div>
                        <div class="text-xs font-mono">{unit.master_unit.point_value} PV</div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end