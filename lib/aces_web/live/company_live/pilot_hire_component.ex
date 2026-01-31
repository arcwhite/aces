defmodule AcesWeb.CompanyLive.PilotHireComponent do
  @moduledoc """
  LiveComponent for hiring pilots.

  Supports two modes:
  - Company mode (default): Hires pilot using company warchest
  - Campaign mode: Hires pilot using campaign warchest

  ## Assigns

  Required:
  - `company` - The company to add the pilot to
  - `patch` - URL to navigate to after successful hire

  Optional:
  - `campaign` - If provided, uses campaign warchest instead of company warchest
  """
  use AcesWeb, :live_component

  alias Aces.Companies.Pilot
  alias Aces.Companies.Pilots
  alias Aces.Campaigns

  @impl true
  def update(assigns, socket) do
    pilot = %Pilot{}
    changeset = Pilots.change_pilot(pilot)

    # Determine the warchest balance based on mode (campaign or company)
    warchest_balance = get_warchest_balance(assigns)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:pilot, pilot)
     |> assign(:form, to_form(changeset))
     |> assign(:warchest_balance, warchest_balance)
     |> assign_new(:campaign, fn -> nil end)}
  end

  defp get_warchest_balance(%{campaign: %{warchest_balance: balance}}), do: balance
  defp get_warchest_balance(%{company: %{warchest_balance: balance}}), do: balance
  defp get_warchest_balance(_), do: 0

  @impl true
  def handle_event("validate", %{"pilot" => pilot_params}, socket) do
    changeset =
      socket.assigns.pilot
      |> Pilots.change_pilot(pilot_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"pilot" => pilot_params}, socket) do
    if socket.assigns.campaign do
      hire_for_campaign(socket, pilot_params)
    else
      hire_for_company(socket, pilot_params)
    end
  end

  defp hire_for_campaign(socket, pilot_params) do
    campaign = socket.assigns.campaign

    case Campaigns.hire_pilot_for_campaign(campaign, pilot_params) do
      {:ok, pilot, updated_campaign} ->
        notify_parent({:pilot_hired, pilot, updated_campaign})
        {:noreply,
         socket
         |> put_flash(:info, "Pilot #{pilot.name} hired successfully for 150 SP!")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_changeset_error(socket, changeset)

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp hire_for_company(socket, pilot_params) do
    company = socket.assigns.company

    case Pilots.hire_pilot(company, pilot_params) do
      {:ok, pilot, updated_company} ->
        notify_parent({:saved, pilot, updated_company})
        {:noreply,
         socket
         |> put_flash(:info, "Pilot #{pilot.name} hired successfully for 150 SP!")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_changeset_error(socket, changeset)
    end
  end

  defp handle_changeset_error(socket, changeset) do
    # Check for base errors (company/campaign-level validation failures)
    base_errors = Keyword.get_values(changeset.errors, :base)
    if length(base_errors) > 0 do
      {message, _opts} = hd(base_errors)
      {:noreply, put_flash(socket, :error, message)}
    else
      {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h3 class="text-lg font-bold">Hire New Pilot</h3>
        <p class="text-sm opacity-70">Recruit a new pilot for your mercenary company for 150 SP</p>
      </div>

      <div class="alert alert-warning mb-4">
        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
        </svg>
        <span>Hiring cost: <strong>150 SP</strong> | Available: <strong>{@warchest_balance} SP</strong></span>
      </div>

      <.form
        for={@form}
        id="pilot-hire-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="space-y-6"
      >
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

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div class="bg-base-200 p-4 rounded-lg">
            <h4 class="font-semibold mb-2">Starting Stats</h4>
            <div class="space-y-2">
              <div class="flex justify-between">
                <span>Skill Level:</span>
                <span class="badge badge-primary">4 (Default)</span>
              </div>
              <div class="flex justify-between">
                <span>Edge Tokens:</span>
                <span class="badge badge-secondary">1</span>
              </div>
              <div class="flex justify-between">
                <span>Status:</span>
                <span class="badge badge-success">Active</span>
              </div>
            </div>
          </div>

          <div class="bg-base-200 p-4 rounded-lg">
            <h4 class="font-semibold mb-2">Hiring Cost</h4>
            <div class="space-y-2">
              <div class="flex justify-between">
                <span>Base Cost:</span>
                <span class="text-warning font-bold">150 SP</span>
              </div>
              <div class="flex justify-between">
                <span>Current Warchest:</span>
                <span>{@warchest_balance} SP</span>
              </div>
              <div class="flex justify-between">
                <span>After Hiring:</span>
                <span class={if @warchest_balance >= 150, do: "text-success", else: "text-error"}>
                  {max(0, @warchest_balance - 150)} SP
                </span>
              </div>
            </div>
          </div>
        </div>

        <div class="flex gap-4 justify-end">
          <button
            type="submit"
            class="btn btn-primary"
            phx-disable-with="Hiring..."
            disabled={@warchest_balance < 150}
          >
            Hire Pilot for 150 SP
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
