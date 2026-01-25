defmodule AcesWeb.SortieLive.Complete.SpendSP do
  @moduledoc """
  Step 5 of sortie completion wizard: Allocate earned SP to pilots.
  Pilots must spend all their available SP before proceeding.
  """

  # Dialyzer false positive: Ecto.Multi opaque type warnings when piping
  @dialyzer :no_opaque

  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
  alias Aces.Companies.{Authorization, Pilots, Pilot}
  alias Aces.Campaigns.PilotAllocationState
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
         :ok <- validate_sortie_status(sortie, "spend_sp") do
      # Get all pilots in the company
      all_pilots = Pilots.list_company_pilots(company)

      # Load saved allocations from the database (pilot_allocations table)
      saved_allocations = Campaigns.get_sortie_pilot_allocations_as_saved_map(sortie.id)

      # Build allocation state - either from saved data or fresh
      {pilots_with_sp, pilot_allocations} =
        PilotAllocationState.build_all(all_pilots, saved_allocations)

      {:ok,
       socket
       |> assign(:company, company)
       |> assign(:campaign, campaign)
       |> assign(:sortie, sortie)
       |> assign(:pilots_with_sp, pilots_with_sp)
       |> assign(:pilot_allocations, pilot_allocations)
       |> assign(:page_title, "Complete Sortie: Spend SP")}
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
  def handle_event("update_allocation", params, socket) do
    with {:ok, pilot_id} <- safe_parse_id(params["pilot_id"]),
         %{} = allocation <- Map.get(socket.assigns.pilot_allocations, pilot_id) do
      field = params["field"]
      value = parse_int(params["value"])
      updated_allocation = PilotAllocationState.update_allocation(allocation, field, value)
      new_allocations = Map.put(socket.assigns.pilot_allocations, pilot_id, updated_allocation)

      {:noreply, assign(socket, :pilot_allocations, new_allocations)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_edge_ability", %{"pilot_id" => pilot_id_str, "ability" => ability}, socket) do
    with {:ok, pilot_id} <- safe_parse_id(pilot_id_str),
         %{} = allocation <- Map.get(socket.assigns.pilot_allocations, pilot_id) do
      updated_allocation = PilotAllocationState.toggle_edge_ability(allocation, ability)
      new_allocations = Map.put(socket.assigns.pilot_allocations, pilot_id, updated_allocation)

      {:noreply, assign(socket, :pilot_allocations, new_allocations)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", _params, socket) do
    allocations = socket.assigns.pilot_allocations

    # Check if all pilots have spent all their SP
    if not PilotAllocationState.all_valid?(allocations) do
      {:noreply, put_flash(socket, :error, "All pilots must spend their entire SP allocation before proceeding")}
    else
      saved_allocations = PilotAllocationState.all_to_saved_format(allocations)

      # Build a transaction to save all changes atomically
      multi = build_save_transaction(socket, allocations, saved_allocations)

      case Aces.Repo.transaction(multi) do
        {:ok, _results} ->
          {:noreply,
           push_navigate(socket,
             to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{socket.assigns.campaign.id}/sorties/#{socket.assigns.sortie.id}/complete/summary"
           )}

        {:error, _failed_operation, _failed_changeset, _changes_so_far} ->
          {:noreply, put_flash(socket, :error, "Failed to save pilot allocations. Please try again.")}
      end
    end
  end

  defp build_save_transaction(socket, allocations, _saved_allocations) do
    alias Aces.Campaigns.PilotAllocation
    import Ecto.Query

    sortie = socket.assigns.sortie

    # First, delete any existing allocations for this sortie
    delete_query = from(pa in PilotAllocation, where: pa.sortie_id == ^sortie.id)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.delete_all(:delete_existing_allocations, delete_query)

    # Then add pilot updates and fresh allocation inserts
    multi =
      Enum.reduce(allocations, multi, fn {pilot_id, alloc}, multi ->
        pilot = Enum.find(socket.assigns.pilots_with_sp, &(&1.id == pilot_id))

        if pilot do
          # Update pilot record
          changes = PilotAllocationState.to_pilot_changes(alloc)
          changeset = Ecto.Changeset.change(pilot, changes)

          # Create PilotAllocation record for this sortie
          allocation_attrs = %{
            pilot_id: pilot_id,
            sortie_id: sortie.id,
            sp_to_skill: alloc.add_skill,
            sp_to_tokens: alloc.add_tokens,
            sp_to_abilities: alloc.add_abilities,
            edge_abilities_gained: alloc.new_edge_abilities,
            total_sp: alloc.sp_to_spend
          }

          allocation_changeset = PilotAllocation.sortie_changeset(%PilotAllocation{}, allocation_attrs)

          multi
          |> Ecto.Multi.update({:pilot, pilot_id}, changeset)
          |> Ecto.Multi.insert({:pilot_allocation, pilot_id}, allocation_changeset)
        else
          multi
        end
      end)

    # Add sortie update (just update finalization_step, no more pilot_allocations JSON)
    sortie_changeset =
      Ecto.Changeset.change(sortie, %{
        finalization_step: "summary"
      })

    Ecto.Multi.update(multi, :sortie, sortie_changeset)
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end
  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(_), do: 0

  defp safe_parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> {:ok, int}
      :error -> :error
    end
  end
  defp safe_parse_id(value) when is_integer(value), do: {:ok, value}
  defp safe_parse_id(_), do: :error

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-6xl">
      <!-- Header -->
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <.link
            navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/pilots"}
            class="btn btn-ghost btn-sm"
          >
            ← Back to Pilot SP
          </.link>
        </div>

        <h1 class="text-3xl font-bold mb-2">Complete Sortie: Spend SP</h1>
        <p class="text-lg opacity-70">
          Sortie #{@sortie.mission_number}: {@sortie.name}
        </p>

        <!-- Progress Steps -->
        <div class="mt-6">
          <ul class="steps steps-horizontal w-full">
            <li class="step step-primary">Victory Details</li>
            <li class="step step-primary">Unit Status</li>
            <li class="step step-primary">Costs</li>
            <li class="step step-primary">Pilot SP</li>
            <li class="step step-primary">Spend SP</li>
            <li class="step">Summary</li>
          </ul>
        </div>
      </div>

      <%= if Enum.empty?(@pilots_with_sp) do %>
        <div class="alert alert-info mb-6">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
          </svg>
          <span>No pilots have SP to allocate. You can proceed to the summary.</span>
        </div>
      <% else %>
        <div class="alert alert-warning mb-6">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
          </svg>
          <span>All pilots must spend their entire SP allocation before completing the sortie.</span>
        </div>

        <!-- Pilot SP Allocation Cards -->
        <%= for pilot <- @pilots_with_sp do %>
          <% allocation = Map.get(@pilot_allocations, pilot.id) %>
          <div class="card bg-base-200 shadow-xl mb-6">
            <div class="card-body">
              <!-- Pilot Header -->
              <div class="flex justify-between items-center mb-4">
                <div>
                  <h2 class="card-title">
                    {pilot.name}
                    <%= if pilot.callsign do %>
                      <span class="text-sm opacity-70">"{pilot.callsign}"</span>
                    <% end %>
                  </h2>
                  <p class="text-sm opacity-70">
                    SP earned this sortie: {allocation.sp_to_spend}
                  </p>
                </div>
                <div class={[
                  "badge badge-lg",
                  cond do
                    allocation.has_error -> "badge-error"
                    allocation.sp_remaining == 0 -> "badge-success"
                    true -> "badge-warning"
                  end
                ]}>
                  {allocation.sp_remaining} SP remaining
                </div>
              </div>

              <!-- SP Allocation Grid -->
              <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
                <!-- Skill Allocation -->
                <div class="card bg-base-100">
                  <div class="card-body p-4">
                    <h5 class="font-semibold">Skill Training</h5>
                    <p class="text-xs opacity-70">
                      Current: Skill {allocation.skill_level}
                      (was {Pilot.calculate_skill_from_sp(allocation.baseline_skill)})
                    </p>

                    <.form
                      for={%{}}
                      phx-change="update_allocation"
                      class="form-control"
                    >
                      <input type="hidden" name="pilot_id" value={pilot.id} />
                      <input type="hidden" name="field" value="skill" />
                      <label class="label py-1">
                        <span class="label-text text-xs">Add SP to Skill</span>
                      </label>
                      <input
                        type="number"
                        name="value"
                        value={allocation.add_skill}
                        min="0"
                        max={allocation.sp_to_spend}
                        class={[
                          "input input-sm input-bordered w-full",
                          if(allocation.has_error, do: "input-error", else: "")
                        ]}
                      />
                      <p class="text-xs opacity-50 mt-1">
                        Total: {allocation.baseline_skill} + {allocation.add_skill} = {allocation.baseline_skill + allocation.add_skill} SP
                      </p>
                    </.form>

                    <div class="mt-2 space-y-1">
                      <% total_skill_sp = allocation.baseline_skill + allocation.add_skill %>
                      <%= for {skill, cost} <- [{3, 400}, {2, 900}, {1, 1900}, {0, 3400}] do %>
                        <%= if total_skill_sp >= cost do %>
                          <div class="text-xs text-success">✓ Skill {skill} ({cost} SP)</div>
                        <% else %>
                          <div class="text-xs opacity-50">Skill {skill} ({cost} SP)</div>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                </div>

                <!-- Edge Tokens Allocation -->
                <div class="card bg-base-100">
                  <div class="card-body p-4">
                    <h5 class="font-semibold">Edge Tokens</h5>
                    <p class="text-xs opacity-70">
                      Current: {allocation.edge_tokens} tokens
                      (was {Pilot.calculate_edge_tokens_from_sp(allocation.baseline_tokens)})
                    </p>

                    <.form
                      for={%{}}
                      phx-change="update_allocation"
                      class="form-control"
                    >
                      <input type="hidden" name="pilot_id" value={pilot.id} />
                      <input type="hidden" name="field" value="edge_tokens" />
                      <label class="label py-1">
                        <span class="label-text text-xs">Add SP to Edge Tokens</span>
                      </label>
                      <input
                        type="number"
                        name="value"
                        value={allocation.add_tokens}
                        min="0"
                        max={allocation.sp_to_spend}
                        class={[
                          "input input-sm input-bordered w-full",
                          if(allocation.has_error, do: "input-error", else: "")
                        ]}
                      />
                      <p class="text-xs opacity-50 mt-1">
                        Total: {allocation.baseline_tokens} + {allocation.add_tokens} = {allocation.baseline_tokens + allocation.add_tokens} SP
                      </p>
                    </.form>

                    <div class="mt-2 space-y-1">
                      <% total_tokens_sp = allocation.baseline_tokens + allocation.add_tokens %>
                      <%= for {tokens, cost} <- [{2, 60}, {3, 120}, {4, 200}, {5, 300}] do %>
                        <%= if total_tokens_sp >= cost do %>
                          <div class="text-xs text-success">✓ {tokens} tokens ({cost} SP)</div>
                        <% else %>
                          <div class="text-xs opacity-50">{tokens} tokens ({cost} SP)</div>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                </div>

                <!-- Edge Abilities Allocation -->
                <div class="card bg-base-100">
                  <div class="card-body p-4">
                    <h5 class="font-semibold">Edge Abilities</h5>
                    <p class="text-xs opacity-70">
                      Available: {allocation.max_abilities} abilities
                      (was {Pilot.calculate_edge_abilities_from_sp(allocation.baseline_abilities)})
                    </p>

                    <.form
                      for={%{}}
                      phx-change="update_allocation"
                      class="form-control"
                    >
                      <input type="hidden" name="pilot_id" value={pilot.id} />
                      <input type="hidden" name="field" value="edge_abilities" />
                      <label class="label py-1">
                        <span class="label-text text-xs">Add SP to Edge Abilities</span>
                      </label>
                      <input
                        type="number"
                        name="value"
                        value={allocation.add_abilities}
                        min="0"
                        max={allocation.sp_to_spend}
                        class={[
                          "input input-sm input-bordered w-full",
                          if(allocation.has_error, do: "input-error", else: "")
                        ]}
                      />
                      <p class="text-xs opacity-50 mt-1">
                        Total: {allocation.baseline_abilities} + {allocation.add_abilities} = {allocation.baseline_abilities + allocation.add_abilities} SP
                      </p>
                    </.form>

                    <div class="mt-2 space-y-1">
                      <% total_abilities_sp = allocation.baseline_abilities + allocation.add_abilities %>
                      <%= for {abilities, cost} <- [{1, 60}, {2, 180}, {3, 360}, {4, 600}] do %>
                        <%= if total_abilities_sp >= cost do %>
                          <div class="text-xs text-success">✓ {abilities} abilities ({cost} SP)</div>
                        <% else %>
                          <div class="text-xs opacity-50">{abilities} abilities ({cost} SP)</div>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>

              <!-- Edge Abilities Selection -->
              <% total_abilities_count = PilotAllocationState.total_abilities_count(allocation) %>
              <%= if allocation.max_abilities > 0 do %>
                <div class="mt-4">
                  <h5 class="font-semibold mb-2">
                    Select Edge Abilities
                    <span class="badge badge-sm badge-info ml-2">
                      {total_abilities_count}/{allocation.max_abilities}
                    </span>
                  </h5>
                  <div class="flex flex-wrap gap-2">
                    <%= for ability <- Pilot.available_edge_abilities() do %>
                      <% is_baseline = ability in allocation.baseline_edge_abilities %>
                      <% is_new = ability in allocation.new_edge_abilities %>
                      <% is_selected = is_baseline or is_new %>
                      <% is_at_max = total_abilities_count >= allocation.max_abilities %>
                      <button
                        type="button"
                        class={[
                          "btn btn-xs",
                          cond do
                            is_baseline -> "btn-secondary"
                            is_new -> "btn-primary"
                            true -> "btn-outline"
                          end
                        ]}
                        phx-click={if not is_baseline, do: "toggle_edge_ability"}
                        phx-value-pilot_id={pilot.id}
                        phx-value-ability={ability}
                        disabled={is_baseline or (not is_selected and is_at_max)}
                        title={if is_baseline, do: "Previously selected - cannot be removed", else: ""}
                      >
                        {ability}
                        <%= if is_baseline do %>
                          <span class="ml-1">🔒</span>
                        <% end %>
                      </button>
                    <% end %>
                  </div>
                  <%= if length(allocation.baseline_edge_abilities) > 0 do %>
                    <p class="text-xs opacity-50 mt-2">🔒 = Previously selected abilities (cannot be removed)</p>
                  <% end %>
                </div>
              <% end %>

              <!-- Current Stats Summary -->
              <div class="mt-4 p-3 bg-base-300 rounded-lg">
                <div class="grid grid-cols-4 gap-4 text-center">
                  <div>
                    <div class="text-xs opacity-70">Skill</div>
                    <div class="font-bold">{allocation.skill_level}</div>
                  </div>
                  <div>
                    <div class="text-xs opacity-70">Edge Tokens</div>
                    <div class="font-bold">{allocation.edge_tokens}</div>
                  </div>
                  <div>
                    <div class="text-xs opacity-70">Abilities</div>
                    <div class="font-bold">{total_abilities_count}</div>
                  </div>
                  <div>
                    <div class="text-xs opacity-70">SP Left</div>
                    <div class={["font-bold", if(allocation.sp_remaining == 0, do: "text-success", else: "text-warning")]}>
                      {allocation.sp_remaining}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      <% end %>

      <!-- Navigation -->
      <div class="flex justify-between">
        <.link
          navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/pilots"}
          class="btn btn-ghost"
        >
          ← Back
        </.link>
        <button
          type="button"
          class="btn btn-primary"
          phx-click="save"
          disabled={not PilotAllocationState.all_valid?(@pilot_allocations) or PilotAllocationState.any_errors?(@pilot_allocations)}
        >
          Continue to Summary →
        </button>
      </div>
    </div>
    """
  end
end
