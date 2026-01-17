defmodule AcesWeb.SortieLive.Complete.Damage do
  @moduledoc """
  Step 2 of sortie completion wizard: Confirm unit damage status.
  """
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
  alias Aces.Companies.Authorization
  alias Aces.Campaigns.Deployment
  alias AcesWeb.SortieLive.Complete.Helpers

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(%{"company_id" => company_id, "campaign_id" => campaign_id, "id" => sortie_id}, _session, socket) do
    company = Companies.get_company!(company_id)
    campaign = Campaigns.get_campaign!(campaign_id)
    sortie = Campaigns.get_sortie!(sortie_id)
    user = socket.assigns.current_scope.user

    with :ok <- authorize_access(user, company),
         :ok <- validate_sortie_belongs_to_campaign(sortie, campaign, company),
         :ok <- validate_sortie_status(sortie, "damage") do
      # Build deployment status map from current values
      deployment_statuses =
        sortie.deployments
        |> Enum.map(fn d ->
          {d.id,
           %{
             damage_status: d.damage_status || "operational",
             pilot_casualty: d.pilot_casualty || "none",
             is_salvageable: d.was_salvaged || false
           }}
        end)
        |> Map.new()

      {:ok,
       socket
       |> assign(:company, company)
       |> assign(:campaign, campaign)
       |> assign(:sortie, sortie)
       |> assign(:page_title, "Complete Sortie: Unit Status")
       |> assign(:deployment_statuses, deployment_statuses)}
    else
      {:error, message, redirect_path} ->
        {:ok,
         socket
         |> put_flash(:error, message)
         |> push_navigate(to: redirect_path)}
    end
  end

  defp authorize_access(user, company) do
    if Authorization.can?(:edit_company, user, company) do
      :ok
    else
      {:error, "You don't have permission to complete this sortie",
       ~p"/companies/#{company.id}"}
    end
  end

  defp validate_sortie_belongs_to_campaign(sortie, campaign, company) do
    if sortie.campaign_id == campaign.id and campaign.company_id == company.id do
      :ok
    else
      {:error, "Sortie not found",
       ~p"/companies/#{company.id}/campaigns/#{campaign.id}"}
    end
  end

  defp validate_sortie_status(sortie, requested_step) do
    Helpers.validate_step_access(sortie, requested_step)
  end

  @impl true
  def handle_event("update_damage_status", %{"deployment_id" => id_str, "status" => status}, socket) do
    id = String.to_integer(id_str)
    statuses = socket.assigns.deployment_statuses

    updated_statuses =
      Map.update!(statuses, id, fn current ->
        # Reset salvageable when changing from destroyed
        new_salvageable = if status != "destroyed", do: false, else: current.is_salvageable
        %{current | damage_status: status, is_salvageable: new_salvageable}
      end)

    {:noreply, assign(socket, :deployment_statuses, updated_statuses)}
  end

  @impl true
  def handle_event("update_casualty_status", %{"deployment_id" => id_str, "status" => status}, socket) do
    id = String.to_integer(id_str)
    statuses = socket.assigns.deployment_statuses

    updated_statuses =
      Map.update!(statuses, id, fn current ->
        %{current | pilot_casualty: status}
      end)

    {:noreply, assign(socket, :deployment_statuses, updated_statuses)}
  end

  @impl true
  def handle_event("toggle_salvageable", %{"deployment_id" => id_str}, socket) do
    id = String.to_integer(id_str)
    statuses = socket.assigns.deployment_statuses

    updated_statuses =
      Map.update!(statuses, id, fn current ->
        %{current | is_salvageable: !current.is_salvageable}
      end)

    {:noreply, assign(socket, :deployment_statuses, updated_statuses)}
  end

  @impl true
  def handle_event("save", _params, socket) do
    sortie = socket.assigns.sortie
    statuses = socket.assigns.deployment_statuses

    # Update all deployments
    results =
      Enum.map(sortie.deployments, fn deployment ->
        status = Map.get(statuses, deployment.id)

        deployment
        |> Deployment.changeset(%{
          damage_status: status.damage_status,
          pilot_casualty: status.pilot_casualty,
          was_salvaged: status.is_salvageable
        })
        |> Aces.Repo.update()
      end)

    if Enum.all?(results, fn {:ok, _} -> true; _ -> false end) do
      # Update sortie to next step
      {:ok, _} =
        sortie
        |> Ecto.Changeset.change(%{finalization_step: "costs"})
        |> Aces.Repo.update()

      {:noreply,
       push_navigate(socket,
         to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{socket.assigns.campaign.id}/sorties/#{sortie.id}/complete/costs"
       )}
    else
      {:noreply, put_flash(socket, :error, "Failed to save unit statuses")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-4xl">
      <!-- Header -->
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <.link
            navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/outcome"}
            class="btn btn-ghost btn-sm"
          >
            ← Back to Victory Details
          </.link>
        </div>

        <h1 class="text-3xl font-bold mb-2">Complete Sortie: Confirm Unit Status</h1>
        <p class="text-lg opacity-70">
          Sortie #{@sortie.mission_number}: {@sortie.name}
        </p>

        <!-- Progress Steps -->
        <div class="mt-6">
          <ul class="steps steps-horizontal w-full">
            <li class="step step-primary">Victory Details</li>
            <li class="step step-primary">Unit Status</li>
            <li class="step">Costs</li>
            <li class="step">Pilot SP</li>
            <li class="step">Spend SP</li>
            <li class="step">Summary</li>
          </ul>
        </div>
      </div>

      <!-- Unit Status Table -->
      <div class="card bg-base-200 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title">Deployed Units</h2>
          <p class="text-sm opacity-70 mb-4">
            Confirm the final damage status for each unit. Check "Salvageable" for destroyed units that passed their salvage roll (2d6).
          </p>

          <div class="overflow-x-auto">
            <table class="table w-full">
              <thead>
                <tr>
                  <th>Unit</th>
                  <th>Pilot/Crew</th>
                  <th>Damage Status</th>
                  <th>Salvageable?</th>
                  <th>Casualty Status</th>
                </tr>
              </thead>
              <tbody>
                <%= for deployment <- @sortie.deployments do %>
                  <% status = Map.get(@deployment_statuses, deployment.id) %>
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
                        <span class="opacity-50">Unnamed crew</span>
                      <% end %>
                    </td>
                    <td>
                      <select
                        class={[
                          "select select-sm select-bordered",
                          damage_select_class(status.damage_status)
                        ]}
                        phx-change="update_damage_status"
                        phx-value-deployment_id={deployment.id}
                        name="status"
                      >
                        <option value="operational" selected={status.damage_status == "operational"}>Operational</option>
                        <option value="armor_damaged" selected={status.damage_status == "armor_damaged"}>Armor Damaged</option>
                        <option value="structure_damaged" selected={status.damage_status == "structure_damaged"}>Structure Damaged</option>
                        <option value="crippled" selected={status.damage_status == "crippled"}>Crippled</option>
                        <option value="destroyed" selected={status.damage_status == "destroyed"}>Destroyed</option>
                      </select>
                    </td>
                    <td>
                      <%= if status.damage_status == "destroyed" do %>
                        <label class="label cursor-pointer justify-start gap-2">
                          <input
                            type="checkbox"
                            class="checkbox checkbox-success"
                            checked={status.is_salvageable}
                            phx-click="toggle_salvageable"
                            phx-value-deployment_id={deployment.id}
                          />
                          <span class="label-text">Salvageable</span>
                        </label>
                      <% else %>
                        <span class="opacity-50">—</span>
                      <% end %>
                    </td>
                    <td>
                      <select
                        class={[
                          "select select-sm select-bordered",
                          casualty_select_class(status.pilot_casualty)
                        ]}
                        phx-change="update_casualty_status"
                        phx-value-deployment_id={deployment.id}
                        name="status"
                      >
                        <option value="none" selected={status.pilot_casualty == "none"}>Unharmed</option>
                        <option value="wounded" selected={status.pilot_casualty == "wounded"}>Wounded</option>
                        <option value="killed" selected={status.pilot_casualty == "killed"}>Killed</option>
                      </select>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <!-- Navigation -->
      <div class="flex justify-between">
        <.link
          navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/outcome"}
          class="btn btn-ghost"
        >
          ← Back
        </.link>
        <button type="button" class="btn btn-primary" phx-click="save">
          Continue to Costs →
        </button>
      </div>
    </div>
    """
  end

  defp damage_select_class(status) do
    case status do
      "operational" -> "select-success"
      "armor_damaged" -> "select-warning"
      "structure_damaged" -> "select-warning"
      "crippled" -> "select-error"
      "destroyed" -> "select-error"
      _ -> ""
    end
  end

  defp casualty_select_class(status) do
    case status do
      "none" -> "select-success"
      "wounded" -> "select-warning"
      "killed" -> "select-error"
      _ -> ""
    end
  end
end
