defmodule AcesWeb.CompanyLive.FormComponent do
  use AcesWeb, :live_component

  alias Aces.Companies
  alias Aces.Companies.Company

  @impl true
  def update(assigns, socket) do
    changeset = Companies.change_company(assigns.company)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate", %{"company" => company_params}, socket) do
    changeset =
      socket.assigns.company
      |> Companies.change_company(company_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"company" => company_params}, socket) do
    save_company(socket, socket.assigns.action, company_params)
  end

  defp save_company(socket, :new, company_params) do
    user = socket.assigns.current_scope.user

    case Companies.create_company(company_params, user) do
      {:ok, company} ->
        {:noreply,
         socket
         |> put_flash(:info, "Company created successfully")
         |> push_navigate(to: socket.assigns.return_to || ~p"/companies/#{company}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.form
        for={@form}
        id="company-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="space-y-6"
      >
        <.input
          field={@form[:name]}
          type="text"
          label="Company Name"
          placeholder="Enter company name"
          required
        />

        <.input
          field={@form[:description]}
          type="textarea"
          label="Description (Optional)"
          placeholder="Describe your mercenary company..."
          rows="4"
        />

        <.input
          field={@form[:warchest_balance]}
          type="number"
          label="Starting Warchest (SP)"
          placeholder="0"
          min="0"
        />
        <p class="text-sm text-gray-600">Support Points available for purchasing units</p>

        <.input
          field={@form[:pv_budget]}
          type="number"
          label="Alpha Strike PV Budget"
          placeholder="400"
          min="0"
        />
        <p class="text-sm text-gray-600">Point Value budget for initial unit roster (default: 400 PV)</p>

        <div class="flex gap-4 justify-end">
          <.link
            navigate={@return_to || ~p"/companies"}
            class="btn btn-ghost"
          >
            Cancel
          </.link>

          <button type="submit" class="btn btn-primary" phx-disable-with="Creating...">
            Create Company
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
