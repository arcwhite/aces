defmodule AcesWeb.SortieLive.Show do
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns, Units}
  alias Aces.Companies.{Authorization, Pilots}
  alias Aces.Campaigns.Deployment
  alias AcesWeb.SortieLive.Complete.Helpers, as: CompleteHelpers

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

        # For completed sorties, fetch pilot allocations for the summary
        {pilot_allocations, all_pilots} =
          if sortie.status == "completed" do
            allocs = Campaigns.get_sortie_pilot_allocations(sortie.id)
            pilots = Pilots.list_company_pilots(company)
            {allocs, pilots}
          else
            {[], []}
          end

        # For setup status, load OMNI variants for reconfiguration
        omni_variants =
          if sortie.status == "setup" do
            load_omni_variants(sortie.deployments)
          else
            %{}
          end

        {:ok,
         socket
         |> assign(:company, company)
         |> assign(:campaign, campaign)
         |> assign(:sortie, sortie)
         |> assign(:deployed_pilots, deployed_pilots)
         |> assign(:selected_force_commander_id, default_force_commander_id)
         |> assign(:page_title, "Sortie #{sortie.mission_number}: #{sortie.name}")
         |> assign(:can_edit, Authorization.can?(:edit_company, user, company))
         |> assign(:show_fail_modal, false)
         |> assign(:pilot_allocations, pilot_allocations)
         |> assign(:all_pilots, all_pilots)
         |> assign(:omni_variants, omni_variants)
         |> assign(:pending_variant_changes, %{})}
      end
    end
  end

  @impl true
  def handle_event("update_damage_status", params, socket) do
    with :ok <- require_can_edit(socket),
         :ok <- require_sortie_status(socket, "in_progress"),
         {:ok, deployment_id, damage_status} <- extract_damage_params(params),
         {:ok, deployment} <- find_deployment(socket, deployment_id) do
      case update_deployment_damage(deployment, damage_status) do
        {:ok, _updated_deployment} ->
          updated_sortie = Campaigns.get_sortie!(socket.assigns.sortie.id)

          {:noreply,
           socket
           |> assign(:sortie, updated_sortie)
           |> put_flash(:info, "Unit damage updated")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to update damage status")}
      end
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
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
    with :ok <- require_can_edit(socket),
         :ok <- require_sortie_status(socket, "setup"),
         {:ok, force_commander_id} <- require_force_commander_selected(socket),
         :ok <- require_force_commander_deployed(socket, force_commander_id),
         :ok <- require_no_in_progress_sorties(socket),
         :ok <- require_sufficient_warchest_for_refits(socket),
         :ok <- require_pv_within_limit(socket) do

      # First commit all pending variant changes
      pending_changes = socket.assigns.pending_variant_changes
      campaign = Campaigns.get_campaign!(socket.assigns.campaign.id)

      case commit_pending_variant_changes(socket, pending_changes, campaign) do
        {:ok, updated_campaign} ->
          # Now start the sortie
          case Campaigns.start_sortie(socket.assigns.sortie, force_commander_id) do
            {:ok, updated_sortie} ->
              {:noreply,
               socket
               |> assign(:sortie, updated_sortie)
               |> assign(:campaign, updated_campaign)
               |> assign(:pending_variant_changes, %{})
               |> put_flash(:info, "Sortie started successfully!")}

            {:error, %Ecto.Changeset{} = changeset} ->
              {:noreply,
               socket
               |> put_flash(:error, "Cannot start sortie: #{format_changeset_errors(changeset)}")}
          end

        {:error, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("update_pilot_casualty", params, socket) do
    with :ok <- require_can_edit(socket),
         :ok <- require_sortie_status(socket, "in_progress"),
         {:ok, deployment_id, casualty_status} <- extract_casualty_params(params),
         {:ok, deployment} <- find_deployment(socket, deployment_id) do
      case update_deployment_casualty(deployment, casualty_status) do
        {:ok, _updated_deployment} ->
          updated_sortie = Campaigns.get_sortie!(socket.assigns.sortie.id)
          casualty_type = if deployment.pilot_id, do: "Pilot", else: "Crew"

          {:noreply,
           socket
           |> assign(:sortie, updated_sortie)
           |> put_flash(:info, "#{casualty_type} casualty updated")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to update casualty status")}
      end
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("show_fail_modal", _params, socket) do
    {:noreply, assign(socket, :show_fail_modal, true)}
  end

  @impl true
  def handle_event("hide_fail_modal", _params, socket) do
    {:noreply, assign(socket, :show_fail_modal, false)}
  end

  @impl true
  def handle_event("confirm_sortie_failed", %{"notes" => notes}, socket) do
    with :ok <- require_can_edit(socket),
         :ok <- require_sortie_status(socket, "in_progress") do
      attrs = if notes && String.trim(notes) != "", do: %{recon_notes: notes}, else: %{}

      case socket.assigns.sortie
           |> Aces.Campaigns.Sortie.fail_changeset(attrs)
           |> Aces.Repo.update() do
        {:ok, _sortie} ->
          {:noreply,
           socket
           |> put_flash(:info, "Sortie marked as failed. You can retry by creating a new sortie.")
           |> push_navigate(to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{socket.assigns.campaign.id}")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to mark sortie as failed")}
      end
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("begin_finalization", _params, socket) do
    with :ok <- require_can_edit(socket),
         :ok <- require_sortie_status(socket, "in_progress") do
      case socket.assigns.sortie
           |> Aces.Campaigns.Sortie.begin_finalization_changeset()
           |> Aces.Repo.update() do
        {:ok, _sortie} ->
          {:noreply,
           push_navigate(socket,
             to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{socket.assigns.campaign.id}/sorties/#{socket.assigns.sortie.id}/complete/outcome"
           )}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to begin sortie finalization")}
      end
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("change_variant", params, socket) do
    deployment_id_str = params["deployment_id"]
    new_variant_id_str = params["new_variant_id"]

    unless deployment_id_str && new_variant_id_str do
      {:noreply, put_flash(socket, :error, "Missing parameters for variant change")}
    else
      with :ok <- require_can_edit(socket),
           :ok <- require_sortie_status(socket, "setup") do
        deployment_id = String.to_integer(deployment_id_str)
        new_variant_id = String.to_integer(new_variant_id_str)

        deployment = Enum.find(socket.assigns.sortie.deployments, &(&1.id == deployment_id))

        if deployment do
          current_variant_id = deployment.company_unit.master_unit_id

          # Track pending change in socket assigns (not committed until Start Sortie)
          # If selecting back to original variant, remove from pending changes
          pending_changes = socket.assigns.pending_variant_changes

          updated_pending =
            if new_variant_id == current_variant_id do
              Map.delete(pending_changes, deployment_id)
            else
              Map.put(pending_changes, deployment_id, new_variant_id)
            end

          {:noreply, assign(socket, :pending_variant_changes, updated_pending)}
        else
          {:noreply, put_flash(socket, :error, "Deployment not found")}
        end
      else
        {:error, message} -> {:noreply, put_flash(socket, :error, message)}
      end
    end
  end

  defp update_deployment_damage(deployment, damage_status) do
    deployment
    |> Deployment.changeset(%{damage_status: damage_status})
    |> Aces.Repo.update()
  end

  # Load available variants for all OMNI units in the deployment list
  defp load_omni_variants(deployments) do
    deployments
    |> Enum.filter(fn d ->
      d.company_unit && d.company_unit.master_unit && is_omni?(d.company_unit.master_unit)
    end)
    |> Enum.map(fn d ->
      variants = Units.list_variants_for_chassis(d.company_unit.master_unit)
      {d.id, variants}
    end)
    |> Map.new()
  end

  defp is_omni?(master_unit) do
    Units.is_omni?(master_unit)
  end

  # Calculate total cost of all pending variant changes
  # Accepts either a socket or assigns map
  defp calculate_pending_refit_cost(%{assigns: assigns}), do: calculate_pending_refit_cost(assigns)

  defp calculate_pending_refit_cost(assigns) do
    pending = assigns.pending_variant_changes
    deployments = assigns.sortie.deployments
    omni_variants = assigns.omni_variants

    Enum.reduce(pending, 0, fn {deployment_id, new_variant_id}, total ->
      deployment = Enum.find(deployments, &(&1.id == deployment_id))

      if deployment do
        variants = Map.get(omni_variants, deployment_id, [])
        current_unit = deployment.company_unit.master_unit
        new_unit = Enum.find(variants, &(&1.id == new_variant_id))

        if new_unit do
          total + Campaigns.calculate_omni_refit_cost(current_unit, new_unit)
        else
          total
        end
      else
        total
      end
    end)
  end

  # Get the selected variant ID for a deployment (pending or current)
  defp get_selected_variant_id(deployment, pending_changes) do
    Map.get(pending_changes, deployment.id, deployment.company_unit.master_unit_id)
  end

  # Calculate effective deployed PV considering pending variant changes
  # Accepts either a socket or assigns map
  defp calculate_effective_deployed_pv(%{assigns: assigns}), do: calculate_effective_deployed_pv(assigns)

  defp calculate_effective_deployed_pv(assigns) do
    pending = assigns.pending_variant_changes
    omni_variants = assigns.omni_variants
    deployments = assigns.sortie.deployments

    Enum.reduce(deployments, 0, fn deployment, total ->
      base_pv = deployment.company_unit.master_unit.point_value || 0

      # Check if this deployment has a pending variant change
      case Map.get(pending, deployment.id) do
        nil ->
          total + base_pv

        new_variant_id ->
          # Find the new variant's PV
          variants = Map.get(omni_variants, deployment.id, [])
          new_variant = Enum.find(variants, &(&1.id == new_variant_id))

          if new_variant do
            total + (new_variant.point_value || 0)
          else
            total + base_pv
          end
      end
    end)
  end


  defp update_deployment_casualty(deployment, pilot_casualty) do
    deployment
    |> Deployment.changeset(%{pilot_casualty: pilot_casualty})
    |> Aces.Repo.update()
  end

  # Validation helpers for `with` chains
  # These return :ok or {:error, message} to enable clean guard-clause-style validation

  defp require_can_edit(%{assigns: %{can_edit: true}}), do: :ok
  defp require_can_edit(_socket), do: {:error, "You don't have permission to perform this action"}

  defp require_sortie_status(%{assigns: %{sortie: %{status: status}}}, expected) when status == expected, do: :ok
  defp require_sortie_status(%{assigns: %{sortie: %{status: actual}}}, expected) do
    {:error, "Sortie must be in #{expected} state (currently #{actual})"}
  end

  defp require_force_commander_selected(%{assigns: %{selected_force_commander_id: nil}}) do
    {:error, "Please select a Force Commander"}
  end
  defp require_force_commander_selected(%{assigns: %{selected_force_commander_id: id}}), do: {:ok, id}

  defp require_force_commander_deployed(socket, force_commander_id) do
    deployed_pilot_ids =
      socket.assigns.sortie.deployments
      |> Enum.filter(& &1.pilot_id)
      |> Enum.map(& &1.pilot_id)

    if force_commander_id in deployed_pilot_ids do
      :ok
    else
      {:error, "Force Commander must be one of the deployed pilots"}
    end
  end

  defp require_no_in_progress_sorties(socket) do
    campaign = Campaigns.get_campaign!(socket.assigns.campaign.id)
    in_progress_sorties = Enum.filter(campaign.sorties, &(&1.status == "in_progress"))

    if length(in_progress_sorties) > 0 do
      {:error, "Only one sortie can be in progress at a time. Complete the current sortie before starting a new one."}
    else
      :ok
    end
  end

  defp require_sufficient_warchest_for_refits(socket) do
    total_cost = calculate_pending_refit_cost(socket)
    warchest = socket.assigns.campaign.warchest_balance

    if total_cost > warchest do
      {:error, "Insufficient warchest for OMNI refits. Need #{total_cost} SP, have #{warchest} SP."}
    else
      :ok
    end
  end

  defp require_pv_within_limit(socket) do
    effective_pv = calculate_effective_deployed_pv(socket.assigns)
    pv_limit = socket.assigns.sortie.pv_limit

    if effective_pv > pv_limit do
      {:error, "Deployed PV (#{effective_pv}) exceeds sortie limit (#{pv_limit}). Adjust OMNI variants to reduce PV."}
    else
      :ok
    end
  end

  # Commits all pending variant changes to the database
  # Returns {:ok, updated_campaign} or {:error, message}
  defp commit_pending_variant_changes(_socket, pending_changes, campaign) when map_size(pending_changes) == 0 do
    {:ok, campaign}
  end

  defp commit_pending_variant_changes(socket, pending_changes, campaign) do
    case Campaigns.commit_omni_refits(
           socket.assigns.sortie,
           pending_changes,
           socket.assigns.omni_variants,
           campaign
         ) do
      {:ok, updated_campaign} -> {:ok, updated_campaign}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_damage_params(params) do
    case Enum.find_value(params, fn
           {"damage_status_" <> id_string, status} -> {String.to_integer(id_string), status}
           _ -> nil
         end) do
      {deployment_id, damage_status} -> {:ok, deployment_id, damage_status}
      nil -> {:error, "Invalid damage status parameters"}
    end
  end

  defp extract_casualty_params(params) do
    case Enum.find_value(params, fn
           {"pilot_casualty_" <> id_string, status} -> {String.to_integer(id_string), status}
           _ -> nil
         end) do
      {deployment_id, casualty_status} -> {:ok, deployment_id, casualty_status}
      nil -> {:error, "Invalid pilot casualty parameters"}
    end
  end

  defp find_deployment(socket, deployment_id) do
    case Enum.find(socket.assigns.sortie.deployments, &(&1.id == deployment_id)) do
      nil -> {:error, "Deployment not found"}
      deployment -> {:ok, deployment}
    end
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
            <%= if @sortie.status == "setup" and @can_edit do %>
              <.link
                navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/edit"}
                class="btn btn-outline btn-sm"
              >
                Edit Sortie
              </.link>
            <% end %>
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
      <div class="grid grid-cols-2 gap-3 md:gap-6 md:grid-cols-3 mb-8">
        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4">
          <div class="stat-title text-xs md:text-sm">PV Limit</div>
          <div class="stat-value text-xl md:text-3xl text-primary">{@sortie.pv_limit}</div>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4">
          <div class="stat-title text-xs md:text-sm">Deployed</div>
          <%= if @sortie.status == "setup" and map_size(@pending_variant_changes) > 0 do %>
            <% effective_pv = calculate_effective_deployed_pv(assigns) %>
            <% base_pv = Aces.Campaigns.calculate_deployed_pv(@sortie) %>
            <% over_limit = effective_pv > @sortie.pv_limit %>
            <div class={["stat-value text-xl md:text-3xl", over_limit && "text-error" || "text-secondary"]}>
              {effective_pv}
              <%= if effective_pv != base_pv do %>
                <span class={["text-sm", effective_pv > base_pv && "text-warning" || "text-success"]}>
                  (<%= if effective_pv > base_pv do %>+<% end %>{effective_pv - base_pv})
                </span>
              <% end %>
            </div>
            <%= if over_limit do %>
              <div class="text-xs text-error mt-1">Over limit!</div>
            <% end %>
          <% else %>
            <div class="stat-value text-xl md:text-3xl text-secondary">{Aces.Campaigns.calculate_deployed_pv(@sortie)}</div>
          <% end %>
        </div>

        <div class="stat bg-base-200 rounded-lg shadow p-3 md:p-4 col-span-2 md:col-span-1">
          <div class="stat-title text-xs md:text-sm">Force Commander</div>
          <div class="stat-value text-lg md:text-2xl text-accent truncate">
            <%= if @sortie.force_commander do %>
              {@sortie.force_commander.name}
            <% else %>
              TBD
            <% end %>
          </div>
        </div>
      </div>

      <!-- Deploying table (for setup status) -->
      <%= if @sortie.status == "setup" do %>
      <div class="mb-8">
        <h2 class="text-2xl font-bold mb-4">Deploying</h2>

        <%= if length(@sortie.deployments) == 0 do %>
          <div class="alert alert-warning">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.732-.833-2.502 0L4.232 15.5c-.77.833.192 2.5 1.732 2.5z"></path>
            </svg>
            <span>No units deployed yet. <.link navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/edit"} class="link link-primary">Edit sortie</.link> to add units.</span>
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-zebra w-full">
              <thead>
                <tr>
                  <th>Unit</th>
                  <th class="hidden sm:table-cell">Pilot</th>
                  <th class="text-center">A/S</th>
                  <th class="hidden md:table-cell text-center">Dmg</th>
                  <th class="hidden lg:table-cell">Move</th>
                  <th class="hidden xl:table-cell">Specials</th>
                  <%= if @can_edit and map_size(@omni_variants) > 0 do %>
                    <th>Variant</th>
                  <% end %>
                </tr>
              </thead>
              <tbody>
                <%= for deployment <- @sortie.deployments do %>
                  <% original_unit = deployment.company_unit.master_unit %>
                  <% is_omni = Map.has_key?(@omni_variants, deployment.id) %>
                  <% has_pending_change = Map.has_key?(@pending_variant_changes, deployment.id) %>
                  <% # Get the display unit - either the pending variant or the original
                     display_unit = if has_pending_change do
                       variants = Map.get(@omni_variants, deployment.id, [])
                       selected_id = Map.get(@pending_variant_changes, deployment.id)
                       Enum.find(variants, &(&1.id == selected_id)) || original_unit
                     else
                       original_unit
                     end
                  %>
                  <tr class={has_pending_change && "bg-warning/10"}>
                    <td>
                      <div class="font-semibold text-sm">
                        {deployment.company_unit.custom_name || original_unit.name}
                      </div>
                      <%= if has_pending_change do %>
                        <div class="text-xs">
                          <span class="opacity-50">{original_unit.variant}</span>
                          <span class="badge badge-ghost badge-xs">{original_unit.point_value}</span>
                          <span class="text-warning mx-1">→</span>
                          <span class="text-warning font-semibold">{display_unit.variant}</span>
                          <span class="badge badge-warning badge-xs">{display_unit.point_value}</span>
                        </div>
                      <% else %>
                        <div class="text-xs opacity-70">
                          {original_unit.variant}
                          <span class="badge badge-accent badge-xs ml-1">{original_unit.point_value} PV</span>
                        </div>
                      <% end %>
                      <!-- Show pilot on mobile only -->
                      <div class="sm:hidden text-xs mt-1">
                        <%= if deployment.pilot do %>
                          <span class="opacity-70">{deployment.pilot.name}</span>
                        <% else %>
                          <span class="opacity-50">Crew</span>
                        <% end %>
                      </div>
                      <!-- Show mobile stats -->
                      <div class="md:hidden text-xs mt-1 opacity-70">
                        Dmg: {display_unit.bf_damage_short || "0"}/{display_unit.bf_damage_medium || "0"}/{display_unit.bf_damage_long || "0"}
                      </div>
                    </td>
                    <td class="hidden sm:table-cell">
                      <%= if deployment.pilot do %>
                        <div class="font-semibold text-sm">{deployment.pilot.name}</div>
                        <div class="text-xs opacity-70">Skill {deployment.pilot.skill_level}</div>
                      <% else %>
                        <div class="text-sm opacity-70">Crew</div>
                      <% end %>
                    </td>
                    <td class="text-center font-mono text-sm">
                      <span class="text-info">{display_unit.bf_armor || 0}</span>/<span class="text-warning">{display_unit.bf_structure || 0}</span>
                    </td>
                    <td class="hidden md:table-cell text-center font-mono text-sm">
                      {display_unit.bf_damage_short || "0"}/{display_unit.bf_damage_medium || "0"}/{display_unit.bf_damage_long || "0"}
                    </td>
                    <td class="hidden lg:table-cell font-mono text-sm">
                      {display_unit.bf_move || "—"}
                    </td>
                    <td class="hidden xl:table-cell">
                      <%= if display_unit.bf_abilities && display_unit.bf_abilities != "" do %>
                        <span class="text-xs opacity-70 max-w-xs truncate block" title={display_unit.bf_abilities}>
                          {display_unit.bf_abilities}
                        </span>
                      <% else %>
                        <span class="opacity-50">—</span>
                      <% end %>
                    </td>
                    <%= if @can_edit and map_size(@omni_variants) > 0 do %>
                      <td>
                        <%= if is_omni do %>
                          <% variants = Map.get(@omni_variants, deployment.id, []) %>
                          <% original_variant_id = original_unit.id %>
                          <% selected_variant_id = get_selected_variant_id(deployment, @pending_variant_changes) %>
                          <form phx-change="change_variant" id={"variant-form-#{deployment.id}"}>
                            <input type="hidden" name="deployment_id" value={deployment.id} />
                            <select
                              name="new_variant_id"
                              class={["select select-xs sm:select-sm w-full max-w-[140px]", has_pending_change && "select-warning"]}
                            >
                              <%= for variant <- variants do %>
                                <% refit_cost = if variant.id != original_variant_id, do: Campaigns.calculate_omni_refit_cost(original_unit, variant), else: 0 %>
                                <option value={variant.id} selected={variant.id == selected_variant_id}>
                                  {variant.variant} ({variant.point_value} PV)<%= if refit_cost > 0 do %> -{refit_cost} SP<% end %>
                                </option>
                              <% end %>
                            </select>
                          </form>
                          <div class="text-xs opacity-50 mt-1">
                            OMNI<%= if has_pending_change do %> <span class="text-warning">*</span><% end %>
                          </div>
                        <% else %>
                          <span class="opacity-50">—</span>
                        <% end %>
                      </td>
                    <% end %>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <!-- Warchest info for OMNI refits -->
          <%= if @can_edit and map_size(@omni_variants) > 0 do %>
            <% pending_cost = calculate_pending_refit_cost(assigns) %>
            <div class="mt-4 text-sm">
              <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
                <span>
                  <span class="font-semibold">Warchest:</span>
                  <span class="opacity-70">{@campaign.warchest_balance} SP</span>
                </span>
                <%= if pending_cost > 0 do %>
                  <span class="text-warning font-semibold">
                    Pending Refit Cost: -{pending_cost} SP
                  </span>
                  <span class="opacity-70">
                    (After: {@campaign.warchest_balance - pending_cost} SP)
                  </span>
                <% end %>
              </div>
              <div class="text-xs opacity-50 mt-1">
                OMNI refit: Size×5 SP if new PV ≤ current, Size×40 SP if new PV > current
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
      <% end %>

      <!-- Deployment Status (for in_progress status) -->
      <%= if @sortie.status == "in_progress" do %>
      <div class="mb-8">
        <h2 class="text-2xl font-bold mb-4">Deployment Status</h2>

        <div class="overflow-x-auto">
          <table class="table table-zebra w-full">
            <thead>
              <tr>
                <th>Unit</th>
                <th class="hidden sm:table-cell">Pilot</th>
                <th class="hidden md:table-cell">PV</th>
                <th class="hidden lg:table-cell">Unit Stats</th>
                <th>Damage</th>
                <th>Pilot</th>
              </tr>
            </thead>
            <tbody>
              <%= for deployment <- @sortie.deployments do %>
                <tr>
                  <td>
                    <div class="font-semibold text-sm">
                      {deployment.company_unit.custom_name || deployment.company_unit.master_unit.name}
                    </div>
                    <div class="text-xs opacity-70">
                      {deployment.company_unit.master_unit.variant}
                    </div>
                    <!-- Show pilot on mobile only -->
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
                      <div class="text-sm opacity-70">Unnamed crew</div>
                    <% end %>
                  </td>
                  <td class="hidden md:table-cell font-mono text-sm whitespace-nowrap">{deployment.company_unit.master_unit.point_value} PV</td>
                  <td class="hidden lg:table-cell">
                    <div class="text-xs space-y-1">
                      <div class="flex gap-2">
                        <span class="font-semibold">Move:</span>
                        <span class="font-mono">{deployment.company_unit.master_unit.bf_move || "—"}</span>
                      </div>
                      <div class="flex gap-2">
                        <span class="font-semibold">Dmg:</span>
                        <span class="font-mono">
                          {deployment.company_unit.master_unit.bf_damage_short || "0"}/{deployment.company_unit.master_unit.bf_damage_medium || "0"}/{deployment.company_unit.master_unit.bf_damage_long || "0"}
                        </span>
                      </div>
                      <%= if deployment.company_unit.master_unit.bf_abilities && deployment.company_unit.master_unit.bf_abilities != "" do %>
                        <div class="flex gap-2">
                          <span class="font-semibold">Spc:</span>
                          <span class="opacity-70 max-w-xs truncate" title={deployment.company_unit.master_unit.bf_abilities}>
                            {deployment.company_unit.master_unit.bf_abilities}
                          </span>
                        </div>
                      <% end %>
                    </div>
                  </td>
                  <td>
                    <%= if @can_edit do %>
                      <form phx-change="update_damage_status" id={"damage-form-#{deployment.id}"}>
                        <select
                          class={[
                            "select select-xs sm:select-sm w-full max-w-xs",
                            damage_status_color(deployment.damage_status)
                          ]}
                          name={"damage_status_#{deployment.id}"}
                        >
                          <option value="operational" selected={deployment.damage_status == "operational"}>OK</option>
                          <option value="armor_damaged" selected={deployment.damage_status == "armor_damaged"}>Armor</option>
                          <option value="structure_damaged" selected={deployment.damage_status == "structure_damaged"}>Structure</option>
                          <option value="crippled" selected={deployment.damage_status == "crippled"}>Crippled</option>
                          <option value="destroyed" selected={deployment.damage_status == "destroyed"}>Destroyed</option>
                        </select>
                      </form>
                    <% else %>
                      <div class={[
                        "badge badge-xs md:badge-md whitespace-nowrap",
                        damage_status_color(deployment.damage_status)
                      ]}>
                        {format_damage_status(deployment.damage_status)}
                      </div>
                    <% end %>
                  </td>
                  <td>
                    <%= if @can_edit do %>
                      <form phx-change="update_pilot_casualty" id={"casualty-form-#{deployment.id}"}>
                        <select
                          class={[
                            "select select-xs sm:select-sm w-full max-w-xs",
                            casualty_status_color(deployment.pilot_casualty)
                          ]}
                          name={"pilot_casualty_#{deployment.id}"}
                        >
                          <option value="none" selected={deployment.pilot_casualty == "none"}>OK</option>
                          <option value="wounded" selected={deployment.pilot_casualty == "wounded"}>Wounded</option>
                          <option value="killed" selected={deployment.pilot_casualty == "killed"}>Killed</option>
                        </select>
                      </form>
                      <%= if is_nil(deployment.pilot) do %>
                        <div class="text-xs text-gray-500 mt-1 hidden sm:block">Crew: 100 SP</div>
                      <% end %>
                    <% else %>
                      <div class={[
                        "badge badge-xs md:badge-md whitespace-nowrap",
                        casualty_status_color(deployment.pilot_casualty)
                      ]}>
                        {format_casualty_status(deployment.pilot_casualty)}
                      </div>
                      <%= if is_nil(deployment.pilot) and deployment.pilot_casualty != "none" do %>
                        <div class="text-xs text-gray-500 mt-1 hidden sm:block">Crew: 100 SP</div>
                      <% end %>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
      <% end %>

      <!-- Mission Status -->
      <%= if @sortie.status == "setup" and @can_edit do %>
        <% pending_refit_cost = calculate_pending_refit_cost(assigns) %>
        <% insufficient_warchest = pending_refit_cost > @campaign.warchest_balance %>
        <% effective_pv = calculate_effective_deployed_pv(assigns) %>
        <% pv_over_limit = effective_pv > @sortie.pv_limit %>
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

            <%= if pv_over_limit do %>
              <div class="alert alert-error mb-4">
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <span>Deployed PV ({effective_pv}) exceeds sortie limit ({@sortie.pv_limit}). Adjust OMNI variants to reduce PV.</span>
              </div>
            <% end %>

            <%= if insufficient_warchest do %>
              <div class="alert alert-error mb-4">
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <span>Insufficient SP for OMNI refits. Need {pending_refit_cost} SP, have {@campaign.warchest_balance} SP.</span>
              </div>
            <% end %>

            <%= if pending_refit_cost > 0 and not insufficient_warchest and not pv_over_limit do %>
              <div class="alert alert-info mb-4">
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <span>OMNI refit cost: {pending_refit_cost} SP will be deducted from warchest when sortie starts.</span>
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
                disabled={length(@deployed_pilots) == 0 or is_nil(@selected_force_commander_id) or insufficient_warchest or pv_over_limit}
              >
                Start Sortie<%= if pending_refit_cost > 0 do %> (-{pending_refit_cost} SP)<% end %>
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
        <div class="card bg-base-100 shadow-xl mb-8">
          <div class="card-body">
            <div class="flex items-start gap-4">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-info shrink-0 w-6 h-6 mt-1">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
              </svg>
              <div class="flex-1">
                <p class="mb-4">Mission in progress. Mark unit damage and pilot casualties as they occur during play.</p>

                <%= if @can_edit do %>
                  <div class="flex gap-3">
                    <button
                      class="btn btn-error"
                      phx-click="show_fail_modal"
                    >
                      Sortie Failed
                    </button>
                    <button
                      class="btn btn-success"
                      phx-click="begin_finalization"
                    >
                      Sortie Victory
                    </button>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @sortie.status == "finalizing" do %>
        <div class="card bg-warning/20 shadow-xl mb-8">
          <div class="card-body">
            <div class="flex items-start gap-4">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-warning shrink-0 w-6 h-6 mt-1">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"></path>
              </svg>
              <div class="flex-1">
                <h3 class="font-bold text-lg mb-2">Sortie Finalization in Progress</h3>
                <p class="mb-4">
                  This sortie is being finalized. Complete the remaining steps to record the mission outcome.
                </p>
                <.link
                  navigate={CompleteHelpers.complete_step_path(@company.id, @campaign.id, @sortie.id, @sortie.finalization_step)}
                  class="btn btn-warning"
                >
                  Continue Finalization →
                </.link>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @sortie.status == "completed" do %>
        <div class="mb-8">
          <div class="flex items-center gap-3 mb-6">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-success shrink-0 w-8 h-8">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"></path>
            </svg>
            <h2 class="text-2xl font-bold text-success">Sortie Completed - Victory!</h2>
          </div>

          <.sortie_summary
            sortie={@sortie}
            campaign={@campaign}
            pilot_allocations={@pilot_allocations}
            all_pilots={@all_pilots}
          />
        </div>
      <% end %>

      <%= if @sortie.status == "failed" do %>
        <div class="card bg-error/20 shadow-xl mb-8">
          <div class="card-body">
            <div class="flex items-start gap-4">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-error shrink-0 w-6 h-6 mt-1">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"></path>
              </svg>
              <div class="flex-1">
                <h3 class="font-bold text-lg mb-2">Sortie Failed</h3>
                <p class="opacity-70 mb-4">
                  This sortie was marked as failed. No outcomes were applied to your company. You can retry by creating a new sortie with the same mission parameters.
                </p>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <!-- Sortie Failed Modal -->
      <%= if @show_fail_modal do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg">Confirm Sortie Failure</h3>
            <p class="py-4">
              Are you sure the sortie failed? All damage and casualties tracked during play will be kept for reference,
              but no outcomes will be applied to your company.
            </p>
            <p class="text-sm opacity-70 mb-4">
              You can retry this mission by creating a new sortie.
            </p>

            <form phx-submit="confirm_sortie_failed">
              <div class="form-control mb-4">
                <label class="label">
                  <span class="label-text">Notes (optional)</span>
                </label>
                <textarea
                  name="notes"
                  class="textarea textarea-bordered"
                  placeholder="What went wrong?"
                  rows="3"
                ></textarea>
              </div>

              <div class="modal-action">
                <button type="button" class="btn" phx-click="hide_fail_modal">Cancel</button>
                <button type="submit" class="btn btn-error">Confirm Failure</button>
              </div>
            </form>
          </div>
          <div class="modal-backdrop" phx-click="hide_fail_modal"></div>
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

      <!-- Notes (hidden for completed sorties - shown in summary instead) -->
      <%= if @sortie.status != "completed" and @sortie.recon_notes && String.trim(@sortie.recon_notes) != "" do %>
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