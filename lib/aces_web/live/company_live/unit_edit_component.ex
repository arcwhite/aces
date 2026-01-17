defmodule AcesWeb.CompanyLive.UnitEditComponent do
  use AcesWeb, :live_component

  alias Aces.Companies.Units

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        Edit Unit
        <:subtitle>Update custom name and pilot assignment</:subtitle>
      </.header>

      <.form
        for={@form}
        id="unit-edit-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:custom_name]} type="text" label="Custom Name" placeholder="Optional custom name" />
        
        <.input 
          field={@form[:pilot_id]} 
          type="select" 
          label="Assigned Pilot" 
          prompt="Select a pilot..."
          options={@pilot_options}
        />

        <div class="mt-6 flex items-center justify-end gap-x-6">
          <.button type="submit" phx-disable-with="Saving...">Save Unit</.button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def update(%{unit: unit, company: company} = assigns, socket) do
    changeset = Units.change_company_unit(unit)

    # Build pilot options - only include unassigned pilots, plus the currently assigned pilot
    pilot_options = build_pilot_options(company.pilots, unit.pilot_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)
     |> assign(:pilot_options, pilot_options)}
  end

  @impl true
  def handle_event("validate", %{"company_unit" => unit_params}, socket) do
    changeset =
      socket.assigns.unit
      |> Units.change_company_unit(unit_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"company_unit" => unit_params}, socket) do
    save_unit(socket, socket.assigns.action, unit_params)
  end

  defp save_unit(socket, :edit_unit, unit_params) do
    case Units.update_company_unit(socket.assigns.unit, unit_params) do
      {:ok, unit} ->
        notify_parent({:saved, unit})

        {:noreply,
         socket
         |> put_flash(:info, "Unit updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  # Build pilot options, including unassigned pilots and the currently assigned pilot
  defp build_pilot_options(pilots, current_pilot_id) do
    available_pilots = 
      pilots
      |> Enum.filter(fn pilot ->
        # Include pilots that are unassigned OR the currently assigned pilot
        is_nil(pilot.assigned_unit) or pilot.id == current_pilot_id
      end)
      |> Enum.map(fn pilot ->
        display_name = if pilot.callsign && String.trim(pilot.callsign) != "" do
          "\"#{pilot.callsign}\" #{pilot.name}"
        else
          pilot.name
        end
        {display_name, pilot.id}
      end)

    [{"None (Unassigned)", nil} | available_pilots]
  end
end