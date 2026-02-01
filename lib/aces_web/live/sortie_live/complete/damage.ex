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
    deployment = find_deployment(socket.assigns.sortie, id)

    # Reset salvageable when changing from destroyed
    new_salvaged = if status != "destroyed", do: false, else: deployment.was_salvaged

    # Persist to database immediately
    case update_deployment_fields(deployment, %{damage_status: status, was_salvaged: new_salvaged}) do
      {:ok, _updated} ->
        # Reload sortie to get fresh data
        sortie = Campaigns.get_sortie!(socket.assigns.sortie.id)
        {:noreply, assign(socket, :sortie, sortie) |> rebuild_deployment_statuses()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update damage status")}
    end
  end

  @impl true
  def handle_event("update_casualty_status", %{"deployment_id" => id_str, "status" => status}, socket) do
    id = String.to_integer(id_str)
    deployment = find_deployment(socket.assigns.sortie, id)

    # Persist to database immediately
    case update_deployment_fields(deployment, %{pilot_casualty: status}) do
      {:ok, _updated} ->
        # Reload sortie to get fresh data
        sortie = Campaigns.get_sortie!(socket.assigns.sortie.id)
        {:noreply, assign(socket, :sortie, sortie) |> rebuild_deployment_statuses()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update casualty status")}
    end
  end

  @impl true
  def handle_event("toggle_salvageable", %{"deployment_id" => id_str}, socket) do
    id = String.to_integer(id_str)
    deployment = find_deployment(socket.assigns.sortie, id)

    # Persist to database immediately
    new_salvaged = !deployment.was_salvaged

    case update_deployment_fields(deployment, %{was_salvaged: new_salvaged}) do
      {:ok, _updated} ->
        # Reload sortie to get fresh data
        sortie = Campaigns.get_sortie!(socket.assigns.sortie.id)
        {:noreply, assign(socket, :sortie, sortie) |> rebuild_deployment_statuses()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update salvage status")}
    end
  end

  @impl true
  def handle_event("save", _params, socket) do
    sortie = socket.assigns.sortie

    # Changes are already persisted - just advance to next step
    {:ok, _} =
      sortie
      |> Ecto.Changeset.change(%{finalization_step: "costs"})
      |> Aces.Repo.update()

    {:noreply,
     push_navigate(socket,
       to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{socket.assigns.campaign.id}/sorties/#{sortie.id}/complete/costs"
     )}
  end

  defp find_deployment(sortie, deployment_id) do
    Enum.find(sortie.deployments, &(&1.id == deployment_id))
  end

  defp update_deployment_fields(deployment, attrs) do
    deployment
    |> Deployment.changeset(attrs)
    |> Aces.Repo.update()
  end

  defp rebuild_deployment_statuses(socket) do
    deployment_statuses =
      socket.assigns.sortie.deployments
      |> Enum.map(fn d ->
        {d.id,
         %{
           damage_status: d.damage_status || "operational",
           pilot_casualty: d.pilot_casualty || "none",
           is_salvageable: d.was_salvaged || false
         }}
      end)
      |> Map.new()

    assign(socket, :deployment_statuses, deployment_statuses)
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
        <div class="mt-6 overflow-x-auto">
          <ul class="steps steps-horizontal w-full min-w-[500px]">
            <li class="step step-primary text-xs md:text-sm">Victory</li>
            <li class="step step-primary text-xs md:text-sm">Damage</li>
            <li class="step text-xs md:text-sm">Costs</li>
            <li class="step text-xs md:text-sm">Pilot SP</li>
            <li class="step text-xs md:text-sm">Spend SP</li>
            <li class="step text-xs md:text-sm">Summary</li>
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
                  <th class="hidden sm:table-cell">Pilot/Crew</th>
                  <th>Damage</th>
                  <th class="hidden sm:table-cell">Salvage?</th>
                  <th>Casualty</th>
                </tr>
              </thead>
              <tbody>
                <%= for deployment <- @sortie.deployments do %>
                  <% status = Map.get(@deployment_statuses, deployment.id) %>
                  <tr>
                    <td>
                      <div class="font-semibold text-sm">
                        {deployment.company_unit.custom_name || deployment.company_unit.master_unit.name}
                      </div>
                      <div class="text-xs opacity-70">
                        {deployment.company_unit.master_unit.variant}
                      </div>
                      <!-- Show pilot on mobile -->
                      <div class="sm:hidden text-xs mt-1">
                        <%= if deployment.pilot do %>
                          <span class="opacity-70">{deployment.pilot.name}</span>
                        <% else %>
                          <span class="opacity-50">Crew</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="hidden sm:table-cell">
                      <%= if deployment.pilot do %>
                        <div class="font-semibold text-sm">{deployment.pilot.name}</div>
                        <div class="text-xs opacity-70">Skill {deployment.pilot.skill_level}</div>
                      <% else %>
                        <span class="opacity-50">Unnamed crew</span>
                      <% end %>
                    </td>
                    <td>
                      <select
                        class={[
                          "select select-xs sm:select-sm select-bordered w-full max-w-[120px]",
                          damage_select_class(status.damage_status)
                        ]}
                        phx-change="update_damage_status"
                        phx-value-deployment_id={deployment.id}
                        name="status"
                      >
                        <option value="operational" selected={status.damage_status == "operational"}>OK</option>
                        <option value="armor_damaged" selected={status.damage_status == "armor_damaged"}>Armor</option>
                        <option value="structure_damaged" selected={status.damage_status == "structure_damaged"}>Structure</option>
                        <option value="crippled" selected={status.damage_status == "crippled"}>Crippled</option>
                        <option value="destroyed" selected={status.damage_status == "destroyed"}>Destroyed</option>
                      </select>
                      <!-- Show salvage checkbox on mobile under damage select -->
                      <%= if status.damage_status == "destroyed" do %>
                        <label class="label cursor-pointer justify-start gap-1 sm:hidden p-0 mt-1">
                          <input
                            type="checkbox"
                            class="checkbox checkbox-success checkbox-xs"
                            checked={status.is_salvageable}
                            phx-click="toggle_salvageable"
                            phx-value-deployment_id={deployment.id}
                          />
                          <span class="label-text text-xs">Salvage</span>
                        </label>
                      <% end %>
                    </td>
                    <td class="hidden sm:table-cell">
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
                          "select select-xs sm:select-sm select-bordered w-full max-w-[100px]",
                          casualty_select_class(status.pilot_casualty)
                        ]}
                        phx-change="update_casualty_status"
                        phx-value-deployment_id={deployment.id}
                        name="status"
                      >
                        <option value="none" selected={status.pilot_casualty == "none"}>OK</option>
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
