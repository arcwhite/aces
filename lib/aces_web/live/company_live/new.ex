defmodule AcesWeb.CompanyLive.New do
  use AcesWeb, :live_view

  alias Aces.Companies
  alias Aces.Companies.{Authorization, Company}

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    unless Authorization.can?(:create_company, user, nil) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/companies")}
    else
      {:ok,
       socket
       |> assign(:page_title, "New Company")
       |> assign(:company, %Company{})}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-2xl">
      <div class="mb-8">
        <.link navigate={~p"/companies"} class="btn btn-ghost btn-sm mb-4">
          ← Back to Companies
        </.link>
        <h1 class="text-4xl font-bold">Create New Company</h1>
        <p class="text-lg opacity-70 mt-2">Set up your mercenary company</p>
      </div>

      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <.live_component
            module={AcesWeb.CompanyLive.FormComponent}
            id={:new}
            action={:new}
            company={@company}
            current_scope={@current_scope}
            return_to={~p"/companies"}
          />
        </div>
      </div>
    </div>
    """
  end
end
