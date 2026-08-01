defmodule AcesWeb.Components.UnitSearchModal do
  @moduledoc """
  A reusable LiveComponent for searching and selecting units from the Master Unit List.

  ## Usage

  This component handles the search UI, filters, and results display. The parent LiveView
  is responsible for:
  - Controlling visibility via the `show` assign
  - Handling the `:unit_selected` message when a unit is chosen
  - Handling the `:close_modal` message when the modal is dismissed

  ## Modes

  - `:pv_budget` - For draft company setup, shows PV cost and checks against PV budget
  - `:sp_purchase` - For campaign purchases, shows SP cost and checks against warchest

  ## Example

      <.live_component
        module={AcesWeb.Components.UnitSearchModal}
        id="unit-search"
        show={@show_unit_search}
        mode={:sp_purchase}
        budget={@campaign.warchest_balance}
        error={@unit_add_error}
      />

  Then in the parent LiveView:

      def handle_info({AcesWeb.Components.UnitSearchModal, {:unit_selected, mul_id}}, socket) do
        # Handle unit selection
      end

      def handle_info({AcesWeb.Components.UnitSearchModal, :close_modal}, socket) do
        {:noreply, assign(socket, :show_unit_search, false)}
      end
  """

  use AcesWeb, :live_component

  require Logger

  alias Aces.MUL.Vocabulary
  alias Aces.Units

  @impl true
  def update(assigns, socket) do
    previous_show = Map.get(socket.assigns, :show, false)
    show = assigns[:show]

    socket =
      if socket.assigns[:initialized] do
        socket
        |> assign(:show, show)
        |> assign(:budget, assigns[:budget])
        |> assign(:mode, assigns[:mode])
        |> assign(:error, assigns[:error])
      else
        socket
        |> assign(assigns)
        |> assign(:initialized, true)
        |> assign(:filter_eras, ["ilclan", "dark_age"])
        |> assign(:filter_faction, "mercenary")
        |> assign(:filter_type, nil)
        |> reset_search()
      end

    socket =
      cond do
        previous_show != true and show == true ->
          socket
          |> reset_search()
          |> load_default_results()

        previous_show == true and show != true ->
          reset_search(socket)

        true ->
          socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("close", _params, socket) do
    notify_parent(:close_modal)
    {:noreply, reset_search(socket)}
  end

  def handle_event("toggle_era_filter", %{"era" => era}, socket) do
    current_eras = socket.assigns.filter_eras

    new_eras =
      if era in current_eras do
        List.delete(current_eras, era)
      else
        [era | current_eras]
      end

    socket =
      socket
      |> assign(:filter_eras, new_eras)
      |> refresh_results()

    {:noreply, socket}
  end

  def handle_event("set_faction_filter", %{"faction" => faction}, socket) do
    faction_value = if faction == "", do: nil, else: faction

    socket =
      socket
      |> assign(:filter_faction, faction_value)
      |> refresh_results()

    {:noreply, socket}
  end

  def handle_event("set_type_filter", %{"type" => type}, socket) do
    type_value = if type == "", do: nil, else: type

    socket =
      socket
      |> assign(:filter_type, type_value)
      |> refresh_results()

    {:noreply, socket}
  end

  def handle_event("search", %{"value" => search_term}, socket) do
    search_term = String.trim(search_term)

    socket =
      if String.length(search_term) >= 2 do
        socket
        |> assign(:search_term, search_term)
        |> assign(:search_loading, true)
        |> perform_search()
      else
        socket
        |> assign(:search_term, search_term)
        |> load_default_results()
      end

    {:noreply, socket}
  end

  def handle_event("retry_search", _params, socket) do
    if socket.assigns.search_term != "" do
      {:noreply, socket |> assign(:search_loading, true) |> perform_search()}
    else
      {:noreply, load_default_results(socket)}
    end
  end

  def handle_event("select_unit", %{"mul_id" => mul_id_str}, socket) do
    case Integer.parse(mul_id_str) do
      {mul_id, _} ->
        notify_parent({:unit_selected, mul_id})
        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  # Re-run whichever view is active (search or default) after a filter change.
  defp refresh_results(socket) do
    if String.length(socket.assigns.search_term) >= 2 do
      perform_search(socket)
    else
      load_default_results(socket)
    end
  end

  defp perform_search(socket) do
    opts = current_filter_opts(socket.assigns)

    case Units.search(socket.assigns.search_term, opts) do
      # MUL was reached and had nothing. Distinct from an empty local cache,
      # so the template can say which one happened. `source` is still passed
      # through: knowing an empty result came from fixtures rather than the
      # live MUL is exactly what smoke operators need to see.
      {:ok, %{units: [], source: source}} when source != :local ->
        assign_results(socket, [], source, :mul_empty)

      {:ok, %{units: units, source: source}} ->
        assign_results(socket, units, source, nil)

      {:error, :term_too_short} ->
        assign_results(socket, [], nil, nil)

      {:error, {:mul_unavailable, reason}} ->
        assign_results(socket, [], nil, {:mul_unavailable, reason})

      {:error, {:query_failed, reason}} ->
        Logger.error("Unit search query failed: #{inspect(reason)}")
        assign_results(socket, [], nil, :query_failed)
    end
  end

  defp load_default_results(socket) do
    # The context returns a typed result now, so the view no longer rescues
    # Postgrex errors itself.
    case Units.list_cached_master_units(current_filter_opts(socket.assigns)) do
      {:ok, []} ->
        assign_results(socket, [], nil, :cache_empty)

      {:ok, units} ->
        assign_results(socket, units, :local, nil)

      {:error, {:query_failed, reason}} ->
        Logger.error("Default unit load failed: #{inspect(reason)}")
        assign_results(socket, [], nil, :query_failed)
    end
  end

  # Single place that writes the four result assigns, so every branch above
  # stays one line. `source` is data provenance (:local/:api/:fixture or nil);
  # `error` is the render-state atom the template matches on.
  defp assign_results(socket, units, source, error) do
    socket
    |> assign(:search_results, units)
    |> assign(:search_source, source)
    |> assign(:search_error, error)
    |> assign(:search_loading, false)
  end

  # Clears the term as well as the results, so reopening the modal starts from
  # a blank search rather than a stale one.
  defp reset_search(socket) do
    socket
    |> assign(:search_term, "")
    |> assign_results([], nil, nil)
  end

  defp current_filter_opts(assigns) do
    Units.build_search_opts_from_filters(%{
      eras: assigns.filter_eras,
      faction: assigns.filter_faction,
      type: assigns.filter_type
    })
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  # Calculate SP cost for a unit (PV * 40)
  defp unit_sp_cost(unit), do: (unit.point_value || 0) * 40

  # Check if user can afford unit based on mode
  defp can_afford?(unit, assigns) do
    case assigns.mode do
      :pv_budget ->
        (unit.point_value || 0) <= (assigns.budget || 0)

      :sp_purchase ->
        unit_sp_cost(unit) <= (assigns.budget || 0)
    end
  end

  # Get button text based on mode
  defp select_button_text(unit, mode) do
    case mode do
      :pv_budget -> "Add Unit"
      :sp_purchase -> "Purchase (#{unit_sp_cost(unit)} SP)"
    end
  end

  # Get modal title based on mode
  defp modal_title(mode) do
    case mode do
      :pv_budget -> "Add Unit to Roster"
      :sp_purchase -> "Purchase Unit"
    end
  end

  defp source_label(:local), do: "from local cache"
  defp source_label(:api), do: "from Master Unit List"
  # Smoke/test environments run the fixture-backed client; say so rather than
  # implying these rows came off the live MUL.
  defp source_label(:fixture), do: "from local fixtures (MUL live access disabled)"
  defp source_label(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal show={@show} on_close="close" max_width="4xl" phx-target={@myself}>
        <:title>{modal_title(@mode)}</:title>

        <div class="mb-4">
          <!-- Budget/Warchest info for SP purchase mode -->
          <%= if @mode == :sp_purchase do %>
            <div class="alert alert-info mb-4">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                class="stroke-current shrink-0 w-6 h-6"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                >
                </path>
              </svg>
              <div>
                <div class="font-semibold">Warchest: {@budget} SP</div>
                <div class="text-sm">Unit cost = PV × 40 SP</div>
              </div>
            </div>
          <% end %>
          
    <!-- Error display -->
          <%= if @error do %>
            <div class="alert alert-error mb-4">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="stroke-current shrink-0 h-6 w-6"
                fill="none"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              <span>{@error}</span>
            </div>
          <% end %>

          <input
            type="text"
            name="search"
            placeholder="Search for units (e.g. Atlas, Timber Wolf, Locust...)"
            class="input input-bordered w-full"
            value={@search_term}
            phx-keyup="search"
            phx-target={@myself}
            phx-debounce="300"
          />
          <p class="text-sm text-gray-600 mt-2">
            Units are sourced from
            <a href="https://masterunitlist.info" target="_blank" class="link">
              Master Unit List
            </a>
            with respect and attribution.
          </p>
        </div>
        
    <!-- Filters -->
        <div class="bg-base-200 p-4 rounded-lg mb-4">
          <div class="flex flex-wrap gap-4">
            <!-- Era Filter -->
            <div>
              <label class="label">
                <span class="label-text font-semibold">Era</span>
              </label>
              <div class="flex flex-wrap gap-2">
                <button
                  :for={era <- Vocabulary.availability_eras()}
                  type="button"
                  phx-click="toggle_era_filter"
                  phx-value-era={era.key}
                  phx-target={@myself}
                  class={"btn btn-sm #{if era.key in @filter_eras, do: "btn-primary", else: "btn-outline"}"}
                >
                  {era.label}
                </button>
              </div>
            </div>
            
    <!-- Faction Filter -->
            <div>
              <label class="label">
                <span class="label-text font-semibold">Faction</span>
              </label>
              <form phx-change="set_faction_filter" phx-target={@myself}>
                <select class="select select-bordered select-sm" name="faction">
                  <option value="" selected={is_nil(@filter_faction)}>Any Faction</option>
                  <%= for {group_label, factions} <- Vocabulary.faction_option_groups() do %>
                    <%= if group_label do %>
                      <optgroup label={group_label}>
                        <option
                          :for={faction <- factions}
                          value={faction.key}
                          selected={@filter_faction == faction.key}
                        >
                          {faction.label}
                        </option>
                      </optgroup>
                    <% else %>
                      <option
                        :for={faction <- factions}
                        value={faction.key}
                        selected={@filter_faction == faction.key}
                      >
                        {faction.label}
                      </option>
                    <% end %>
                  <% end %>
                </select>
              </form>
            </div>
            
    <!-- Unit Type Filter -->
            <div>
              <label class="label">
                <span class="label-text font-semibold">Unit Type</span>
              </label>
              <form phx-change="set_type_filter" phx-target={@myself}>
                <select class="select select-bordered select-sm" name="type">
                  <option value="" selected={@filter_type == nil}>All Types</option>
                  <option
                    :for={unit_type <- Vocabulary.unit_types()}
                    value={unit_type.key}
                    selected={@filter_type == unit_type.key}
                  >
                    {unit_type.label}
                  </option>
                </select>
              </form>
            </div>
          </div>
        </div>

        <div class="divider"></div>

        <div class="max-h-96 overflow-y-auto">
          <%= cond do %>
            <% @search_loading -> %>
              <div class="flex justify-center py-8">
                <span class="loading loading-spinner loading-lg"></span>
              </div>
            <% length(@search_results) > 0 -> %>
              <div class="flex flex-col gap-1 mb-3">
                <div class="flex items-baseline justify-between">
                  <span class="text-sm text-gray-600" data-role="result-count">
                    {length(@search_results)} unit{if length(@search_results) == 1, do: "", else: "s"}
                  </span>
                  <%= if source_label(@search_source) do %>
                    <span class="text-xs text-gray-500" data-role="source-indicator">
                      {source_label(@search_source)}
                    </span>
                  <% end %>
                </div>
                <%= if match?({:mul_unavailable, _}, @search_error) do %>
                  <div class="alert alert-warning py-2" data-role="mul-unavailable-banner">
                    <span class="text-sm">
                      Couldn't reach the Master Unit List ({inspect(elem(@search_error, 1))}). Showing local results only.
                    </span>
                    <button
                      type="button"
                      phx-click="retry_search"
                      phx-target={@myself}
                      class="btn btn-sm"
                    >
                      Retry
                    </button>
                  </div>
                <% end %>
              </div>
              <div class="grid gap-3">
                <%= for unit <- @search_results do %>
                  <.unit_card
                    unit={unit}
                    mode={@mode}
                    can_afford={can_afford?(unit, assigns)}
                    myself={@myself}
                  />
                <% end %>
              </div>
            <% @search_error == :cache_empty -> %>
              <div class="text-center py-8" data-role="cache-empty">
                <p class="text-gray-600">
                  Unit cache is empty. Run <code class="text-xs bg-base-200 px-2 py-1 rounded">mix seed_master_units --matrix</code>.
                </p>
              </div>
            <% @search_error == :mul_empty -> %>
              <div class="text-center py-8" data-role="mul-empty">
                <p class="text-gray-600">No units match "{@search_term}" with these filters.</p>
              </div>
            <% match?({:mul_unavailable, _}, @search_error) -> %>
              <div class="text-center py-8" data-role="mul-unavailable">
                <div class="alert alert-warning inline-flex">
                  <span>
                    Couldn't reach the Master Unit List ({inspect(elem(@search_error, 1))}). Showing local results only.
                  </span>
                </div>
                <div class="mt-3">
                  <button
                    type="button"
                    phx-click="retry_search"
                    phx-target={@myself}
                    class="btn btn-sm"
                  >
                    Retry
                  </button>
                </div>
              </div>
            <% @search_error == :query_failed -> %>
              <div class="text-center py-8" data-role="query-failed">
                <div class="alert alert-error inline-flex">
                  <span>Something went wrong looking up units. Please try again.</span>
                </div>
              </div>
            <% @search_term != "" -> %>
              <div class="text-center py-8">
                <p class="text-gray-600">No units found for "{@search_term}"</p>
                <p class="text-sm text-gray-500 mt-2">
                  Try searching by chassis name (e.g., "Atlas" instead of "AS7-D")
                </p>
              </div>
            <% true -> %>
              <div class="text-center py-8">
                <p class="text-gray-600">
                  Search for units to {if @mode == :pv_budget,
                    do: "add to your company roster",
                    else: "purchase for your company"}
                </p>
              </div>
          <% end %>
        </div>
      </.modal>
    </div>
    """
  end

  defp unit_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow compact">
      <div class="card-body">
        <div class="flex flex-col sm:flex-row sm:justify-between sm:items-start gap-3">
          <div class="flex-1 min-w-0">
            <h4 class="card-title text-base">
              {Aces.Units.MasterUnit.display_name(@unit)}
            </h4>
            <div class="flex flex-wrap gap-1.5 mt-2">
              <div class="badge badge-outline badge-sm">
                {String.replace(@unit.unit_type, "_", " ") |> String.capitalize()}
              </div>
              <%= if @unit.tonnage do %>
                <div class="badge badge-neutral badge-sm">{@unit.tonnage}t</div>
              <% end %>
              <%= if @unit.point_value do %>
                <div class="badge badge-accent badge-sm">{@unit.point_value} PV</div>
              <% end %>
            </div>
            <%= if @unit.role do %>
              <p class="text-sm text-gray-600 mt-1">Role: {@unit.role}</p>
            <% end %>
            <!-- Alpha Strike Stats -->
            <div class="flex flex-wrap gap-x-3 gap-y-1 mt-2 text-xs text-gray-600">
              <%= if @unit.bf_move do %>
                <span title="Movement"><span class="font-semibold">MV:</span> {@unit.bf_move}</span>
              <% end %>
              <%= if @unit.bf_armor || @unit.bf_structure do %>
                <span title="Armor / Structure">
                  <span class="font-semibold">A/S:</span> {@unit.bf_armor || 0}/{@unit.bf_structure ||
                    0}
                </span>
              <% end %>
              <%= if @unit.bf_damage_short || @unit.bf_damage_medium || @unit.bf_damage_long do %>
                <span title="Damage (Short/Medium/Long)">
                  <span class="font-semibold">DMG:</span> {@unit.bf_damage_short || "-"}/{@unit.bf_damage_medium ||
                    "-"}/{@unit.bf_damage_long || "-"}
                </span>
              <% end %>
              <%= if @unit.bf_overheat && @unit.bf_overheat > 0 do %>
                <span title="Overheat">
                  <span class="font-semibold">OV:</span> {@unit.bf_overheat}
                </span>
              <% end %>
            </div>
            <%= if @unit.bf_abilities && @unit.bf_abilities != "" do %>
              <p class="text-xs text-gray-500 mt-1" title="Special Abilities">
                <span class="font-semibold">Specials:</span> {@unit.bf_abilities}
              </p>
            <% end %>
            <% factions = Aces.Units.MasterUnit.available_factions(@unit) %>
            <%= if factions != [] do %>
              <div class="flex flex-wrap gap-1 mt-2">
                <%= for faction <- Enum.take(factions, 3) do %>
                  <div class="badge badge-ghost badge-xs">{String.capitalize(faction)}</div>
                <% end %>
                <%= if length(factions) > 3 do %>
                  <div class="badge badge-ghost badge-xs">+{length(factions) - 3}</div>
                <% end %>
              </div>
            <% end %>
          </div>
          <div class="flex sm:flex-col items-center sm:items-end gap-2 sm:shrink-0">
            <%= if @can_afford do %>
              <button
                type="button"
                phx-click="select_unit"
                phx-value-mul_id={@unit.mul_id}
                phx-target={@myself}
                class="btn btn-primary btn-sm"
              >
                {select_button_text(@unit, @mode)}
              </button>
            <% else %>
              <button
                type="button"
                disabled
                class="btn btn-disabled btn-sm"
                title={
                  if @mode == :pv_budget,
                    do: "Insufficient PV budget",
                    else: "Insufficient SP in warchest"
                }
              >
                Too Expensive
              </button>
            <% end %>
            <div class="flex gap-1">
              <a
                href={Aces.Units.MasterUnit.mul_url(@unit)}
                target="_blank"
                class="btn btn-ghost btn-xs"
                title="View on MasterUnitList.info"
              >
                MUL ↗
              </a>
              <a
                href={Aces.Units.MasterUnit.sarna_url(@unit)}
                target="_blank"
                class="btn btn-ghost btn-xs"
                title="Search on Sarna.net"
              >
                Sarna ↗
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
