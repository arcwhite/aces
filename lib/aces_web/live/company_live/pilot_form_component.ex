defmodule AcesWeb.CompanyLive.PilotFormComponent do
  use AcesWeb, :live_component

  alias Aces.Companies

  @impl true
  def update(%{pilot: pilot} = assigns, socket) do
    changeset = Companies.change_pilot(pilot)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate", %{"pilot" => pilot_params}, socket) do
    changeset =
      socket.assigns.pilot
      |> Companies.change_pilot(pilot_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"pilot" => pilot_params}, socket) do
    save_pilot(socket, socket.assigns.action, pilot_params)
  end

  defp save_pilot(socket, :new, pilot_params) do
    company = socket.assigns.company

    case Companies.create_pilot(company, pilot_params) do
      {:ok, pilot} ->
        notify_parent({:saved, pilot})
        {:noreply,
         socket
         |> put_flash(:info, "Pilot #{pilot.name} added successfully!")
         |> push_patch(to: socket.assigns.patch)}

      {:error, :pilot_limit_reached} ->
        {:noreply, put_flash(socket, :error, "Cannot add more than 6 pilots during company creation")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_pilot(socket, :edit, pilot_params) do
    pilot = socket.assigns.pilot

    case Companies.update_pilot(pilot, pilot_params) do
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

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h3 class="text-lg font-bold"><%= @title %></h3>
        <p class="text-sm opacity-70">Add a skilled pilot to your mercenary company</p>
      </div>

      <.form
        for={@form}
        id="pilot-form"
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
            <h4 class="font-semibold mb-2">Career</h4>
            <div class="space-y-2">
              <div class="flex justify-between">
                <span>SP Earned:</span>
                <span>0 SP</span>
              </div>
              <div class="flex justify-between">
                <span>Sorties:</span>
                <span>0</span>
              </div>
              <div class="flex justify-between">
                <span>MVP Awards:</span>
                <span>0</span>
              </div>
            </div>
          </div>
        </div>

        <div class="flex gap-4 justify-end">
          <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
            Save Pilot
          </button>
        </div>
      </.form>
    </div>
    """
  end
end