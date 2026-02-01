defmodule AcesWeb.Components.PilotCard do
  @moduledoc """
  Reusable component for displaying pilot information in a card format.
  Used by both Company show and Campaign Pilots tab.
  """
  use Phoenix.Component

  alias Aces.Units.MasterUnit

  @doc """
  Renders a grid of pilot cards.

  ## Attributes

    * `:pilots` - List of pilot structs to display
    * `:show_actions` - Whether to show action buttons (default: false)
    * `:compact` - Use a more compact layout (default: false)

  """
  attr :pilots, :list, required: true
  attr :show_actions, :boolean, default: false
  attr :compact, :boolean, default: false

  def pilot_cards(assigns) do
    ~H"""
    <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
      <%= for pilot <- @pilots do %>
        <.pilot_card pilot={pilot} show_actions={@show_actions} compact={@compact} />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a single pilot card with all their stats and information.

  ## Attributes

    * `:pilot` - The pilot struct to display
    * `:show_actions` - Whether to show action buttons (default: false)
    * `:compact` - Use a more compact layout (default: false)

  """
  attr :pilot, :map, required: true
  attr :show_actions, :boolean, default: false
  attr :compact, :boolean, default: false

  def pilot_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <!-- Name and Callsign -->
        <h3 class="card-title">
          <%= if @pilot.callsign && String.trim(@pilot.callsign) != "" do %>
            "<%= @pilot.callsign %>" <%= @pilot.name %>
          <% else %>
            <%= @pilot.name %>
          <% end %>
        </h3>

        <!-- Description -->
        <%= if not @compact and @pilot.description && String.trim(@pilot.description) != "" do %>
          <p class="text-sm opacity-70"><%= @pilot.description %></p>
        <% end %>

        <!-- Primary Stats Badges -->
        <div class="flex flex-wrap gap-2 mt-2">
          <div class="badge badge-primary">Skill {@pilot.skill_level}</div>
          <div class="badge badge-secondary">Edge {@pilot.edge_tokens}</div>
          <div class={[
            "badge",
            @pilot.status == "active" && "badge-success",
            @pilot.status == "wounded" && "badge-warning",
            @pilot.status == "deceased" && "badge-error"
          ]}>
            {String.capitalize(@pilot.status)}
          </div>
        </div>

        <!-- Edge Abilities -->
        <%= if @pilot.edge_abilities && length(@pilot.edge_abilities) > 0 do %>
          <div class="flex flex-wrap gap-1 mt-2">
            <%= for ability <- @pilot.edge_abilities do %>
              <span class="badge badge-accent badge-sm">{ability}</span>
            <% end %>
          </div>
        <% end %>

        <!-- Stats -->
        <div class="mt-2 text-sm opacity-70">
          <div class="grid grid-cols-2 gap-x-4 gap-y-1">
            <div>SP Earned: <span class="font-mono">{@pilot.sp_earned}</span></div>
            <div>Sorties: <span class="font-mono">{@pilot.sorties_participated}</span></div>
            <%= if @pilot.mvp_awards > 0 do %>
              <div class="text-warning">MVP Awards: <span class="font-mono">{@pilot.mvp_awards}</span></div>
            <% end %>
            <%= if @pilot.wounds > 0 do %>
              <div class="text-error">Wounds: <span class="font-mono">{@pilot.wounds}</span></div>
            <% end %>
          </div>

          <!-- Assigned Unit -->
          <div class="mt-2">
            <%= if @pilot.assigned_unit do %>
              <div class="text-info">
                Assigned: {MasterUnit.display_name(@pilot.assigned_unit.master_unit)}
              </div>
            <% else %>
              <div class="text-gray-500">Unassigned</div>
            <% end %>
          </div>
        </div>

        <!-- Actions -->
        <%= if @show_actions do %>
          <div class="card-actions justify-end">
            <button
              class="btn btn-ghost btn-sm md:btn-xs"
              phx-click="edit_pilot"
              phx-value-pilot_id={@pilot.id}
            >
              Edit
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a compact pilot roster as a table instead of cards.
  Useful when space is limited or for a more data-dense view.

  ## Attributes

    * `:pilots` - List of pilot structs to display

  """
  attr :pilots, :list, required: true

  def pilot_roster_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-zebra w-full">
        <thead>
          <tr>
            <th>Pilot</th>
            <th class="text-center">Skill</th>
            <th class="text-center">Edge</th>
            <th>Abilities</th>
            <th>Status</th>
            <th class="hidden sm:table-cell">Assigned Unit</th>
            <th class="text-right hidden md:table-cell">SP Earned</th>
            <th class="text-center hidden md:table-cell">Sorties</th>
          </tr>
        </thead>
        <tbody>
          <%= for pilot <- @pilots do %>
            <tr>
              <td>
                <div class="font-semibold">{pilot.name}</div>
                <%= if pilot.callsign && String.trim(pilot.callsign) != "" do %>
                  <div class="text-sm opacity-70">"{pilot.callsign}"</div>
                <% end %>
              </td>
              <td class="text-center">
                <span class="badge badge-primary badge-sm">{pilot.skill_level}</span>
              </td>
              <td class="text-center">
                <span class="badge badge-secondary badge-sm">{pilot.edge_tokens}</span>
              </td>
              <td>
                <%= if pilot.edge_abilities && length(pilot.edge_abilities) > 0 do %>
                  <div class="flex flex-wrap gap-1">
                    <%= for ability <- pilot.edge_abilities do %>
                      <span class="badge badge-accent badge-xs">{ability}</span>
                    <% end %>
                  </div>
                <% else %>
                  <span class="opacity-50">—</span>
                <% end %>
              </td>
              <td>
                <span class={[
                  "badge badge-sm",
                  pilot.status == "active" && "badge-success",
                  pilot.status == "wounded" && "badge-warning",
                  pilot.status == "deceased" && "badge-error"
                ]}>
                  {String.capitalize(pilot.status)}
                </span>
                <%= if pilot.wounds > 0 do %>
                  <span class="text-xs text-error ml-1">({pilot.wounds} wounds)</span>
                <% end %>
              </td>
              <td class="hidden sm:table-cell">
                <%= if pilot.assigned_unit do %>
                  <span class="text-info text-sm">{MasterUnit.display_name(pilot.assigned_unit.master_unit)}</span>
                <% else %>
                  <span class="opacity-50">Unassigned</span>
                <% end %>
              </td>
              <td class="text-right font-mono hidden md:table-cell">{pilot.sp_earned}</td>
              <td class="text-center hidden md:table-cell">
                {pilot.sorties_participated}
                <%= if pilot.mvp_awards > 0 do %>
                  <span class="badge badge-warning badge-xs ml-1" title="MVP Awards">{pilot.mvp_awards}</span>
                <% end %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end
end
