defmodule AcesWeb.CompanyLive.PilotFormComponent do
  @moduledoc """
  LiveComponent for creating and editing pilots with full SP allocation.

  Supports three modes via the `action` assign:
  - `:new` - Creating a pilot during company draft (free, no SP cost)
  - `:edit` - Editing an existing pilot
  - `:hire` - Hiring a pilot for a campaign (costs 150 SP from campaign warchest)

  ## Required Assigns

  - `pilot` - The Pilot struct (use %Pilot{} for new/hire)
  - `company` - The company to add the pilot to
  - `action` - One of :new, :edit, or :hire
  - `patch` - URL to navigate to after successful save

  ## Optional Assigns (for :hire mode)

  - `campaign` - The campaign (required for :hire mode)
  """
  use AcesWeb, :live_component

  alias Aces.Companies.Pilot
  alias Aces.Companies.Pilots
  alias Aces.Campaigns

  @impl true
  def update(%{pilot: pilot} = assigns, socket) do
    changeset = Pilots.change_pilot(pilot)
    available_abilities = Pilot.available_edge_abilities()
    max_abilities = Pilot.calculate_edge_abilities_from_sp(pilot.sp_allocated_to_edge_abilities)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))
     |> assign(:available_edge_abilities, available_abilities)
     |> assign(:max_allowed_abilities, max_abilities)
     |> assign(:sp_allocation_error, false)
     |> assign_new(:campaign, fn -> nil end)
     |> assign(:sp_costs, %{
       skill: Pilot.skill_sp_required(pilot.skill_level - 1),
       edge_tokens: Pilot.edge_tokens_sp_required((pilot.edge_tokens || 1) + 1),
       edge_abilities: Pilot.edge_abilities_sp_required(length(pilot.edge_abilities || []) + 1)
     })}
  end

  defp handle_sp_allocation_update(pilot_params, socket) do
    current_pilot = socket.assigns.pilot

    # Extract SP allocation values, handling empty strings and missing fields
    skill_sp = case pilot_params["sp_allocated_to_skill"] do
      "" -> 0
      nil -> current_pilot.sp_allocated_to_skill
      val ->
        try do
          parsed = String.to_integer(val)
          if parsed < 0, do: 0, else: parsed
        rescue
          ArgumentError -> 0
        end
    end

    tokens_sp = case pilot_params["sp_allocated_to_edge_tokens"] do
      "" -> 0
      nil -> current_pilot.sp_allocated_to_edge_tokens
      val ->
        try do
          parsed = String.to_integer(val)
          if parsed < 0, do: 0, else: parsed
        rescue
          ArgumentError -> 0
        end
    end

    abilities_sp = case pilot_params["sp_allocated_to_edge_abilities"] do
      "" -> 0
      nil -> current_pilot.sp_allocated_to_edge_abilities
      val ->
        try do
          parsed = String.to_integer(val)
          if parsed < 0, do: 0, else: parsed
        rescue
          ArgumentError -> 0
        end
    end

    total_allocated = skill_sp + tokens_sp + abilities_sp
    total_sp = 150 + (current_pilot.sp_earned || 0)

    # Always update pilot with new allocations and calculate derived fields
    updated_pilot = %{current_pilot |
      sp_allocated_to_skill: skill_sp,
      sp_allocated_to_edge_tokens: tokens_sp,
      sp_allocated_to_edge_abilities: abilities_sp,
      sp_available: total_sp - total_allocated,
      skill_level: Pilot.calculate_skill_from_sp(skill_sp),
      edge_tokens: Pilot.calculate_edge_tokens_from_sp(tokens_sp)
    }

    max_abilities = Pilot.calculate_edge_abilities_from_sp(abilities_sp)

    # Trim edge abilities if user has too many selected
    current_abilities = updated_pilot.edge_abilities || []
    trimmed_abilities = Enum.take(current_abilities, max_abilities)
    updated_pilot = %{updated_pilot | edge_abilities: trimmed_abilities}

    # Check if allocation is invalid for validation state
    has_sp_error = total_allocated > total_sp
    has_individual_error = skill_sp > total_sp or tokens_sp > total_sp or abilities_sp > total_sp

    socket
    |> assign(:pilot, updated_pilot)
    |> assign(:max_allowed_abilities, max_abilities)
    |> assign(:sp_allocation_error, has_sp_error or has_individual_error)
  end

  @impl true
  def handle_event("validate", %{"pilot" => pilot_params}, socket) do
    # Handle SP allocation updates if any SP fields are present
    socket = if Map.has_key?(pilot_params, "sp_allocated_to_skill") or
                Map.has_key?(pilot_params, "sp_allocated_to_edge_tokens") or
                Map.has_key?(pilot_params, "sp_allocated_to_edge_abilities") do
      handle_sp_allocation_update(pilot_params, socket)
    else
      socket
    end

    changeset =
      socket.assigns.pilot
      |> Pilots.change_pilot(pilot_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("toggle_edge_ability", %{"ability" => ability}, socket) do
    pilot = socket.assigns.pilot
    current_abilities = pilot.edge_abilities || []
    max_allowed = socket.assigns.max_allowed_abilities

    new_abilities = if ability in current_abilities do
      List.delete(current_abilities, ability)
    else
      if length(current_abilities) < max_allowed do
        [ability | current_abilities]
      else
        current_abilities
      end
    end

    updated_pilot = %{pilot | edge_abilities: new_abilities}
    
    # Preserve current form data when creating new changeset
    current_form_data = socket.assigns.form.params || %{}
    changeset = 
      updated_pilot
      |> Pilots.change_pilot(current_form_data)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:pilot, updated_pilot)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("save", %{"pilot" => pilot_params}, socket) do
    # Check for validation errors before saving
    if socket.assigns.sp_allocation_error do
      {:noreply, put_flash(socket, :error, "Cannot save: Please fix SP allocation errors first")}
    else
      # Merge form params with current pilot state to include edge abilities
      current_pilot = socket.assigns.pilot
      merged_params = Map.merge(pilot_params, %{
        "edge_abilities" => current_pilot.edge_abilities || [],
        "sp_allocated_to_skill" => current_pilot.sp_allocated_to_skill,
        "sp_allocated_to_edge_tokens" => current_pilot.sp_allocated_to_edge_tokens,
        "sp_allocated_to_edge_abilities" => current_pilot.sp_allocated_to_edge_abilities,
        "sp_available" => current_pilot.sp_available,
        "skill_level" => current_pilot.skill_level,
        "edge_tokens" => current_pilot.edge_tokens
      })

      save_pilot(socket, socket.assigns.action, merged_params)
    end
  end

  defp save_pilot(socket, :new, pilot_params) do
    company = socket.assigns.company

    case Pilots.create_pilot(company, pilot_params) do
      {:ok, pilot} ->
        notify_parent({:saved, pilot})
        {:noreply,
         socket
         |> put_flash(:info, "Pilot #{pilot.name} added successfully!")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Check for base errors (company-level validation failures like pilot limit)
        base_errors = Keyword.get_values(changeset.errors, :base)
        if length(base_errors) > 0 do
          {message, _opts} = hd(base_errors)
          {:noreply, put_flash(socket, :error, message)}
        else
          {:noreply, assign(socket, form: to_form(changeset))}
        end
    end
  end

  defp save_pilot(socket, :edit, pilot_params) do
    pilot = socket.assigns.pilot

    case Pilots.update_pilot(pilot, pilot_params) do
      {:ok, pilot} ->
        notify_parent({:saved, pilot})
        {:noreply,
         socket
         |> put_flash(:info, "Pilot #{pilot.name} updated successfully!")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_pilot(socket, :hire, pilot_params) do
    campaign = socket.assigns.campaign

    case Campaigns.hire_pilot_for_campaign(campaign, pilot_params) do
      {:ok, pilot, updated_campaign} ->
        notify_parent({:pilot_hired, pilot, updated_campaign})
        {:noreply,
         socket
         |> put_flash(:info, "Pilot #{pilot.name} hired successfully for 150 SP!")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Check for base errors (campaign-level validation failures)
        base_errors = Keyword.get_values(changeset.errors, :base)
        if length(base_errors) > 0 do
          {message, _opts} = hd(base_errors)
          {:noreply, put_flash(socket, :error, message)}
        else
          {:noreply, assign(socket, form: to_form(changeset))}
        end

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h3 class="text-lg font-bold"><%= @title %></h3>
        <p class="text-sm opacity-70">
          <%= if @action == :hire do %>
            Hire a new pilot for 150 SP and allocate their starting skills
          <% else %>
            Create a skilled pilot and allocate their starting 150 SP
          <% end %>
        </p>
      </div>

      <%= if @action == :hire do %>
        <div class="alert alert-warning mb-4">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
          </svg>
          <span>Hiring cost: <strong>150 SP</strong> | Campaign Warchest: <strong><%= @campaign.warchest_balance %> SP</strong></span>
        </div>
      <% end %>

      <.form
        for={@form}
        id="pilot-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="space-y-6"
      >
        <!-- Basic Info -->
        <div class="card bg-base-200">
          <div class="card-body">
            <h4 class="card-title">Basic Information</h4>
            <div class="space-y-4">
              <.input field={@form[:name]} type="text" label="Pilot Name" placeholder="Enter pilot name" required />
              <.input field={@form[:callsign]} type="text" label="Callsign (Optional)" placeholder="e.g., 'Maverick'" />
              <.input
                field={@form[:description]}
                type="textarea"
                label="Description (Optional)"
                placeholder="Background, personality, specializations..."
                rows="3"
              />
              <.input
                field={@form[:portrait_url]}
                type="text"
                label="Portrait URL (Optional)"
                placeholder="https://example.com/pilot-image.jpg"
              />
            </div>
          </div>
        </div>

        <!-- SP Allocation -->
        <div class="card bg-base-200">
          <div class="card-body">
            <h4 class="card-title">
              SP Allocation
              <div class="badge badge-primary ml-2">
                <%= @pilot.sp_available %> SP Available
              </div>
            </h4>

            <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
              <!-- Skill Allocation -->
              <div class="card bg-base-100">
                <div class="card-body">
                  <h5 class="card-title text-sm">Skill Training</h5>
                  <p class="text-xs opacity-70">Current: Skill <%= @pilot.skill_level %></p>

                  <div class="space-y-2">
                    <label class="label">
                      <span class="label-text text-xs">SP Allocated</span>
                    </label>
                    <input
                      id={"sp-allocated-skill-#{@myself}"}
                      type="number"
                      name="pilot[sp_allocated_to_skill]"
                      value={@pilot.sp_allocated_to_skill}
                      min="0"
                      max={150 + (@pilot.sp_earned || 0)}
                      class={[
                        "input input-sm input-bordered w-full",
                        if(@sp_allocation_error, do: "input-error", else: "")
                      ]}
                      phx-hook="ValidateSP"
                      data-max-sp={150 + (@pilot.sp_earned || 0)}
                    />

                    <div class="space-y-1">
                      <%= for {skill, cost} <- [{3, 400}, {2, 900}, {1, 1900}, {0, 3400}] do %>
                        <%= if @pilot.sp_allocated_to_skill >= cost do %>
                          <div class="text-xs text-success">✓ Skill <%= skill %> (<%= cost %> SP)</div>
                        <% else %>
                          <div class="text-xs opacity-50">Skill <%= skill %> (<%= cost %> SP)</div>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>

              <!-- Edge Tokens Allocation -->
              <div class="card bg-base-100">
                <div class="card-body">
                  <h5 class="card-title text-sm">Edge Tokens</h5>
                  <p class="text-xs opacity-70">Current: <%= @pilot.edge_tokens %> tokens</p>

                  <div class="space-y-2">
                    <label class="label">
                      <span class="label-text text-xs">SP Allocated</span>
                    </label>
                    <input
                      id={"sp-allocated-edge-tokens-#{@myself}"}
                      type="number"
                      name="pilot[sp_allocated_to_edge_tokens]"
                      value={@pilot.sp_allocated_to_edge_tokens}
                      min="0"
                      max={150 + (@pilot.sp_earned || 0)}
                      class={[
                        "input input-sm input-bordered w-full",
                        if(@sp_allocation_error, do: "input-error", else: "")
                      ]}
                      phx-hook="ValidateSP"
                      data-max-sp={150 + (@pilot.sp_earned || 0)}
                    />

                    <div class="space-y-1">
                      <%= for {tokens, cost} <- [{2, 60}, {3, 120}, {4, 200}, {5, 300}] do %>
                        <%= if @pilot.sp_allocated_to_edge_tokens >= cost do %>
                          <div class="text-xs text-success">✓ <%= tokens %> tokens (<%= cost %> SP)</div>
                        <% else %>
                          <div class="text-xs opacity-50"><%= tokens %> tokens (<%= cost %> SP)</div>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>

              <!-- Edge Abilities Allocation -->
              <div class="card bg-base-100">
                <div class="card-body">
                  <h5 class="card-title text-sm">Edge Abilities</h5>
                  <p class="text-xs opacity-70">Available: <%= @max_allowed_abilities %> abilities</p>

                  <div class="space-y-2">
                    <label class="label">
                      <span class="label-text text-xs">SP Allocated</span>
                    </label>
                    <input
                      id={"sp-allocated-edge-abilities-#{@myself}"}
                      type="number"
                      name="pilot[sp_allocated_to_edge_abilities]"
                      value={@pilot.sp_allocated_to_edge_abilities}
                      min="0"
                      max={150 + (@pilot.sp_earned || 0)}
                      class={[
                        "input input-sm input-bordered w-full",
                        if(@sp_allocation_error, do: "input-error", else: "")
                      ]}
                      phx-hook="ValidateSP"
                      data-max-sp={150 + (@pilot.sp_earned || 0)}
                    />

                    <div class="space-y-1">
                      <%= for {abilities, cost} <- [{1, 60}, {2, 180}, {3, 360}, {4, 600}] do %>
                        <%= if @pilot.sp_allocated_to_edge_abilities >= cost do %>
                          <div class="text-xs text-success">✓ <%= abilities %> abilities (<%= cost %> SP)</div>
                        <% else %>
                          <div class="text-xs opacity-50"><%= abilities %> abilities (<%= cost %> SP)</div>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <!-- SP Balance Display -->
            <div class="mt-4 p-3 bg-base-300 rounded-lg">
              <div class="flex justify-between items-center text-sm">
                <span>Total SP Available:</span>
                <span class="font-bold"><%= 150 + (@pilot.sp_earned || 0) %></span>
              </div>
              <div class="flex justify-between items-center text-sm">
                <span>Total SP Allocated:</span>
                <span class="font-bold"><%= @pilot.sp_allocated_to_skill + @pilot.sp_allocated_to_edge_tokens + @pilot.sp_allocated_to_edge_abilities %></span>
              </div>
              <div class="divider my-1"></div>
              <div class="flex justify-between items-center text-sm font-bold">
                <span>SP Remaining:</span>
                <span class={["badge", if(@pilot.sp_available >= 0, do: "badge-success", else: "badge-error")]}>
                  <%= @pilot.sp_available %>
                </span>
              </div>
            </div>
          </div>
        </div>

        <!-- Edge Abilities Selection -->
        <%= if @max_allowed_abilities > 0 do %>
          <div class="card bg-base-200">
            <div class="card-body">
              <h4 class="card-title">
                Select Edge Abilities
                <div class="badge badge-info ml-2">
                  <%= length(@pilot.edge_abilities || []) %>/<%= @max_allowed_abilities %>
                </div>
              </h4>

              <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-2">
                <%= for ability <- @available_edge_abilities do %>
                  <button
                    type="button"
                    class={[
                      "btn btn-sm",
                      if(ability in (@pilot.edge_abilities || []), do: "btn-primary", else: "btn-outline")
                    ]}
                    phx-click="toggle_edge_ability"
                    phx-target={@myself}
                    phx-value-ability={ability}
                    disabled={ability not in (@pilot.edge_abilities || []) and length(@pilot.edge_abilities || []) >= @max_allowed_abilities}
                  >
                    <%= ability %>
                  </button>
                <% end %>
              </div>

              <%= if length(@pilot.edge_abilities || []) > @max_allowed_abilities do %>
                <div class="alert alert-warning">
                  <span>You have too many abilities selected. Remove some to proceed.</span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <!-- Current Stats Summary -->
        <div class="card bg-base-200">
          <div class="card-body">
            <h4 class="card-title">Current Stats</h4>
            <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
              <div class="stat">
                <div class="stat-title">Skill Level</div>
                <div class="stat-value text-lg"><%= @pilot.skill_level %></div>
              </div>
              <div class="stat">
                <div class="stat-title">Edge Tokens</div>
                <div class="stat-value text-lg"><%= @pilot.edge_tokens %></div>
              </div>
              <div class="stat">
                <div class="stat-title">Edge Abilities</div>
                <div class="stat-value text-lg"><%= length(@pilot.edge_abilities || []) %></div>
              </div>
              <div class="stat">
                <div class="stat-title">SP Available</div>
                <div class="stat-value text-lg"><%= @pilot.sp_available %></div>
              </div>
            </div>
          </div>
        </div>

        <!-- Validation Alerts -->
        <%= if @sp_allocation_error do %>
          <div class="alert alert-error">
            <span>⚠️ SP allocation is invalid. Please correct the highlighted fields before saving.</span>
          </div>
        <% end %>

        <!-- Hidden fields for derived values and edge abilities -->
        <input type="hidden" name="pilot[sp_available]" value={@pilot.sp_available} />
        <input type="hidden" name="pilot[skill_level]" value={@pilot.skill_level} />
        <input type="hidden" name="pilot[edge_tokens]" value={@pilot.edge_tokens} />
        <input type="hidden" name="pilot[edge_abilities]" value={Jason.encode!(@pilot.edge_abilities || [])} />

        <div class="flex gap-4 justify-end">
          <button
            type="submit"
            class="btn btn-primary"
            phx-disable-with={if @action == :hire, do: "Hiring...", else: "Saving..."}
            disabled={@sp_allocation_error or length(@pilot.edge_abilities || []) > @max_allowed_abilities}
          >
            <%= if @action == :hire do %>
              Hire Pilot for 150 SP
            <% else %>
              Save Pilot
            <% end %>
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
