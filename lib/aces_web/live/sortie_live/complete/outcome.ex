defmodule AcesWeb.SortieLive.Complete.Outcome do
  @moduledoc """
  Step 1 of sortie completion wizard: Record victory details and income.
  """
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
  alias Aces.Companies.Authorization
  alias Aces.Campaigns.Sortie
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
         :ok <- validate_sortie_status(sortie) do
      {:ok,
       socket
       |> assign(:company, company)
       |> assign(:campaign, campaign)
       |> assign(:sortie, sortie)
       |> assign(:page_title, "Complete Sortie: Victory Details")
       |> assign(:form, build_form(sortie))
       |> assign(:keywords, sortie.keywords_gained || [])
       |> assign(:new_keyword, "")}
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

  defp validate_sortie_status(sortie) do
    Helpers.validate_step_access(sortie, "outcome")
  end

  defp build_form(sortie) do
    data = %{
      "primary_objective_income" => sortie.primary_objective_income || 0,
      "secondary_objectives_income" => sortie.secondary_objectives_income || 0,
      "waypoints_income" => sortie.waypoints_income || 0,
      "sp_per_participating_pilot" => sortie.sp_per_participating_pilot || 0,
      "recon_notes" => sortie.recon_notes || ""
    }

    to_form(data, as: "outcome")
  end

  @impl true
  def handle_event("validate", %{"outcome" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: "outcome"))}
  end

  @impl true
  def handle_event("add_keyword", %{"keyword" => keyword}, socket) do
    keyword = String.trim(keyword)

    if keyword != "" and keyword not in socket.assigns.keywords do
      {:noreply,
       socket
       |> assign(:keywords, socket.assigns.keywords ++ [keyword])
       |> assign(:new_keyword, "")}
    else
      {:noreply, assign(socket, :new_keyword, "")}
    end
  end

  @impl true
  def handle_event("remove_keyword", %{"keyword" => keyword}, socket) do
    {:noreply, assign(socket, :keywords, Enum.reject(socket.assigns.keywords, &(&1 == keyword)))}
  end

  @impl true
  def handle_event("update_keyword_input", %{"keyword_input" => value}, socket) do
    {:noreply, assign(socket, :new_keyword, value)}
  end

  @impl true
  def handle_event("update_keyword_input", %{"value" => value}, socket) do
    {:noreply, assign(socket, :new_keyword, value)}
  end

  @impl true
  def handle_event("save", %{"outcome" => params}, socket) do
    sortie = socket.assigns.sortie

    attrs = %{
      primary_objective_income: parse_int(params["primary_objective_income"]),
      secondary_objectives_income: parse_int(params["secondary_objectives_income"]),
      waypoints_income: parse_int(params["waypoints_income"]),
      sp_per_participating_pilot: parse_int(params["sp_per_participating_pilot"]),
      keywords_gained: socket.assigns.keywords,
      recon_notes: params["recon_notes"],
      was_successful: true,
      finalization_step: "damage"
    }

    case sortie
         |> Sortie.changeset(attrs)
         |> Aces.Repo.update() do
      {:ok, _updated_sortie} ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{socket.assigns.campaign.id}/sorties/#{sortie.id}/complete/damage"
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save: #{format_errors(changeset)}")
         |> assign(:form, to_form(params, as: "outcome"))}
    end
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(_), do: 0

  defp format_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
    |> Enum.join(", ")
  end

  defp calculate_adjusted_income(base_income, reward_modifier) do
    round(base_income * reward_modifier)
  end

  defp format_modifier_percentage(modifier) do
    percentage = round((modifier - 1.0) * 100)

    cond do
      percentage > 0 -> "+#{percentage}%"
      percentage < 0 -> "#{percentage}%"
      true -> "0%"
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
            navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}"}
            class="btn btn-ghost btn-sm"
          >
            ← Back to Sortie
          </.link>
        </div>

        <h1 class="text-3xl font-bold mb-2">Complete Sortie: Victory Details</h1>
        <p class="text-lg opacity-70">
          Sortie #{@sortie.mission_number}: {@sortie.name}
        </p>

        <!-- Progress Steps -->
        <div class="mt-6 overflow-x-auto">
          <ul class="steps steps-horizontal w-full min-w-[500px]">
            <li class="step step-primary text-xs md:text-sm">Victory</li>
            <li class="step text-xs md:text-sm">Damage</li>
            <li class="step text-xs md:text-sm">Costs</li>
            <li class="step text-xs md:text-sm">Pilot SP</li>
            <li class="step text-xs md:text-sm">Spend SP</li>
            <li class="step text-xs md:text-sm">Summary</li>
          </ul>
        </div>
      </div>

      <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-6">
        <!-- Income Section -->
        <div class="card bg-base-200 shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Mission Income</h2>
            <p class="text-sm opacity-70 mb-4">
              Enter the SP rewards from your mission. These will be adjusted by your campaign difficulty.
            </p>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Primary Objective Income (SP)</span>
                </label>
                <input
                  type="number"
                  name="outcome[primary_objective_income]"
                  value={@form[:primary_objective_income].value}
                  min="0"
                  class="input input-bordered"
                  placeholder="0"
                />
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Secondary Objectives Income (SP)</span>
                </label>
                <input
                  type="number"
                  name="outcome[secondary_objectives_income]"
                  value={@form[:secondary_objectives_income].value}
                  min="0"
                  class="input input-bordered"
                  placeholder="0"
                />
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Waypoint Adjustments (SP)</span>
                  <span class="label-text-alt">Can be negative</span>
                </label>
                <input
                  type="number"
                  name="outcome[waypoints_income]"
                  value={@form[:waypoints_income].value}
                  class="input input-bordered"
                  placeholder="0"
                />
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Max SP Per Pilot</span>
                  <span class="label-text-alt">From mission description</span>
                </label>
                <input
                  type="number"
                  name="outcome[sp_per_participating_pilot]"
                  value={@form[:sp_per_participating_pilot].value}
                  min="0"
                  class="input input-bordered"
                  placeholder="0"
                />
              </div>
            </div>

            <!-- Income Summary -->
            <div class="mt-6 p-4 bg-base-300 rounded-lg">
              <h3 class="font-semibold mb-3">Income Summary</h3>
              <% base_income = parse_int(@form[:primary_objective_income].value) +
                   parse_int(@form[:secondary_objectives_income].value) +
                   parse_int(@form[:waypoints_income].value) -
                   (@sortie.recon_total_cost || 0) %>
              <% adjusted_income = calculate_adjusted_income(base_income, @campaign.reward_modifier) %>

              <div class="space-y-2 text-sm">
                <div class="flex justify-between">
                  <span>Primary + Secondary + Waypoints:</span>
                  <span class="font-mono">
                    {parse_int(@form[:primary_objective_income].value) + parse_int(@form[:secondary_objectives_income].value) + parse_int(@form[:waypoints_income].value)} SP
                  </span>
                </div>
                <%= if @sortie.recon_total_cost && @sortie.recon_total_cost > 0 do %>
                  <div class="flex justify-between text-warning">
                    <span>Reconnaissance Costs:</span>
                    <span class="font-mono">-{@sortie.recon_total_cost} SP</span>
                  </div>
                <% end %>
                <div class="flex justify-between">
                  <span>Base Income:</span>
                  <span class="font-mono">{base_income} SP</span>
                </div>
                <div class="flex justify-between">
                  <span>
                    Difficulty Modifier ({String.capitalize(@campaign.difficulty_level)}):
                  </span>
                  <span class="font-mono">{format_modifier_percentage(@campaign.reward_modifier)}</span>
                </div>
                <div class="divider my-1"></div>
                <div class="flex justify-between font-bold text-lg">
                  <span>Adjusted Income:</span>
                  <span class="font-mono text-primary">{adjusted_income} SP</span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Keywords Section -->
        <div class="card bg-base-200 shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Keywords Earned</h2>
            <p class="text-sm opacity-70 mb-4">
              Add any keywords gained from this mission. These affect future sorties in the campaign.
            </p>

            <div class="flex gap-2 mb-4">
              <input
                type="text"
                id="keyword-input"
                name="keyword_input"
                value={@new_keyword}
                phx-keyup="update_keyword_input"
                phx-debounce="100"
                class="input input-bordered flex-1"
                placeholder="Enter a keyword..."
              />
              <button
                type="button"
                class="btn btn-primary"
                phx-click="add_keyword"
                phx-value-keyword={@new_keyword}
              >
                Add
              </button>
            </div>

            <%= if length(@keywords) > 0 do %>
              <div class="flex flex-wrap gap-2">
                <%= for keyword <- @keywords do %>
                  <div class="badge badge-lg badge-primary gap-2">
                    {keyword}
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs"
                      phx-click="remove_keyword"
                      phx-value-keyword={keyword}
                    >
                      ✕
                    </button>
                  </div>
                <% end %>
              </div>
            <% else %>
              <p class="text-sm opacity-50 italic">No keywords added yet.</p>
            <% end %>
          </div>
        </div>

        <!-- Notes Section -->
        <div class="card bg-base-200 shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Mission Notes</h2>
            <p class="text-sm opacity-70 mb-4">
              Optional notes about how the mission went.
            </p>

            <textarea
              name="outcome[recon_notes]"
              class="textarea textarea-bordered w-full"
              rows="4"
              placeholder="Any notes about the mission..."
            >{@form[:recon_notes].value}</textarea>
          </div>
        </div>

        <!-- Navigation -->
        <div class="flex justify-between">
          <.link
            navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}"}
            class="btn btn-ghost"
          >
            Cancel
          </.link>
          <button type="submit" class="btn btn-primary">
            Continue to Unit Status →
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
