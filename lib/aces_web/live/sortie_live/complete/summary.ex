defmodule AcesWeb.SortieLive.Complete.Summary do
  @moduledoc """
  Step 5 of sortie completion wizard: Summary and warchest update.
  Also serves as the read-only view for completed sorties.
  """
  use AcesWeb, :live_view

  alias Aces.{Companies, Campaigns}
  alias Aces.Companies.{Authorization, Pilots}
  alias AcesWeb.SortieLive.Complete.Helpers

  on_mount {AcesWeb.UserAuthLive, :default}

  @impl true
  def mount(%{"company_id" => company_id, "campaign_id" => campaign_id, "id" => sortie_id}, _session, socket) do
    company = Companies.get_company!(company_id)
    campaign = Campaigns.get_campaign!(campaign_id)
    sortie = Campaigns.get_sortie!(sortie_id)
    user = socket.assigns.current_scope.user

    with :ok <- authorize_access(user, company, sortie),
         :ok <- validate_sortie_belongs_to_campaign(sortie, campaign, company),
         :ok <- validate_sortie_status(sortie) do
      # Check if this is a read-only view (completed) or finalization
      is_completed = sortie.status == "completed"

      # Redirect completed sorties to the show page which now displays full summary
      if is_completed do
        {:ok,
         socket
         |> push_navigate(to: ~p"/companies/#{company.id}/campaigns/#{campaign.id}/sorties/#{sortie.id}")}
      else
        # Fetch pilot allocations for the summary
        pilot_allocations = Campaigns.get_sortie_pilot_allocations(sortie.id)
        all_pilots = Pilots.list_company_pilots(company)

        {:ok,
         socket
         |> assign(:company, company)
         |> assign(:campaign, campaign)
         |> assign(:sortie, sortie)
         |> assign(:is_completed, is_completed)
         |> assign(:can_edit, Authorization.can?(:edit_company, user, company))
         |> assign(:pilot_allocations, pilot_allocations)
         |> assign(:all_pilots, all_pilots)
         |> assign(:page_title, "Complete Sortie: Summary")}
      end
    else
      {:error, message, redirect_path} ->
        {:ok,
         socket
         |> put_flash(:error, message)
         |> push_navigate(to: redirect_path)}
    end
  end

  defp authorize_access(user, company, sortie) do
    # For completed sorties, view permission is enough
    # For finalizing, edit permission is required
    has_permission =
      if sortie.status == "completed" do
        Authorization.can?(:view_company, user, company)
      else
        Authorization.can?(:edit_company, user, company)
      end

    if has_permission do
      :ok
    else
      {:error, "You don't have permission to view this sortie",
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
    cond do
      # Completed sorties can always view the summary
      sortie.status == "completed" ->
        :ok

      # For finalizing sorties, use the helper to allow backward navigation
      sortie.status == "finalizing" ->
        Helpers.validate_step_access(sortie, "summary")

      true ->
        {:error, "Sortie is not ready for summary",
         ~p"/companies/#{sortie.campaign.company_id}/campaigns/#{sortie.campaign_id}/sorties/#{sortie.id}"}
    end
  end

  @impl true
  def handle_event("complete_sortie", _params, socket) do
    sortie = socket.assigns.sortie
    campaign = socket.assigns.campaign

    # Calculate warchest addition (net earnings minus pilot pay is already in net_earnings)
    warchest_addition = sortie.net_earnings || 0

    # Update campaign warchest
    new_warchest = (campaign.warchest_balance || 0) + warchest_addition

    {:ok, _campaign} =
      campaign
      |> Ecto.Changeset.change(%{warchest_balance: new_warchest})
      |> Aces.Repo.update()

    # Mark sortie as completed
    {:ok, _sortie} =
      sortie
      |> Ecto.Changeset.change(%{
        status: "completed",
        was_successful: true,
        completed_at: DateTime.truncate(DateTime.utc_now(), :second),
        finalization_step: nil
      })
      |> Aces.Repo.update()

    # Heal pilots who were wounded in PREVIOUS sorties
    heal_previously_wounded_pilots(socket.assigns.company, sortie)

    {:noreply,
     socket
     |> put_flash(:info, "Sortie completed! #{warchest_addition} SP added to warchest.")
     |> push_navigate(to: ~p"/companies/#{socket.assigns.company.id}/campaigns/#{campaign.id}")}
  end

  defp heal_previously_wounded_pilots(company, current_sortie) do
    # Get pilots who are wounded but NOT wounded in this sortie
    wounded_in_sortie =
      current_sortie.deployments
      |> Enum.filter(&(&1.pilot_casualty == "wounded" && &1.pilot_id))
      |> Enum.map(& &1.pilot_id)
      |> MapSet.new()

    company
    |> Pilots.list_company_pilots()
    |> Enum.filter(&(&1.status == "wounded" and not MapSet.member?(wounded_in_sortie, &1.id)))
    |> Enum.each(fn pilot ->
      pilot
      |> Ecto.Changeset.change(%{status: "active"})
      |> Aces.Repo.update()
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-4xl">
      <!-- Header -->
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-4">
          <.link
            navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/spend_sp"}
            class="btn btn-ghost btn-sm"
          >
            ← Back to Spend SP
          </.link>
        </div>

        <div class="flex justify-between items-start">
          <div>
            <h1 class="text-3xl font-bold mb-2">Complete Sortie: Summary</h1>
            <p class="text-lg opacity-70">
              Sortie #{@sortie.mission_number}: {@sortie.name}
            </p>
          </div>

          <div class={[
            "badge badge-lg",
            if(@sortie.was_successful, do: "badge-success", else: "badge-error")
          ]}>
            <%= if @sortie.was_successful, do: "Victory", else: "Defeat" %>
          </div>
        </div>

        <!-- Progress Steps -->
        <div class="mt-6">
          <ul class="steps steps-horizontal w-full">
            <li class="step step-primary">Victory Details</li>
            <li class="step step-primary">Unit Status</li>
            <li class="step step-primary">Costs</li>
            <li class="step step-primary">Pilot SP</li>
            <li class="step step-primary">Spend SP</li>
            <li class="step step-primary">Summary</li>
          </ul>
        </div>
      </div>

      <!-- Sortie Summary Component -->
      <.sortie_summary
        sortie={@sortie}
        campaign={@campaign}
        pilot_allocations={@pilot_allocations}
        all_pilots={@all_pilots}
      />

      <!-- Warchest Update -->
      <div class="card bg-base-300 shadow-xl mb-6 mt-6">
        <div class="card-body">
          <h2 class="card-title">Warchest Update</h2>
          <div class="space-y-2 text-lg">
            <div class="flex justify-between">
              <span>Current Warchest:</span>
              <span class="font-mono">{@campaign.warchest_balance || 0} SP</span>
            </div>
            <div class="flex justify-between">
              <span>Net Earnings:</span>
              <span class={[
                "font-mono",
                if((@sortie.net_earnings || 0) >= 0, do: "text-success", else: "text-error")
              ]}>
                {if (@sortie.net_earnings || 0) >= 0, do: "+", else: ""}{@sortie.net_earnings || 0} SP
              </span>
            </div>
            <div class="divider my-1"></div>
            <div class="flex justify-between font-bold text-xl">
              <span>New Warchest Total:</span>
              <span class="font-mono text-primary">
                {(@campaign.warchest_balance || 0) + (@sortie.net_earnings || 0)} SP
              </span>
            </div>
          </div>
        </div>
      </div>

      <!-- Navigation -->
      <div class="flex justify-between">
        <.link
          navigate={~p"/companies/#{@company.id}/campaigns/#{@campaign.id}/sorties/#{@sortie.id}/complete/spend_sp"}
          class="btn btn-ghost"
        >
          ← Back
        </.link>
        <button type="button" class="btn btn-success btn-lg" phx-click="complete_sortie">
          Complete Sortie
        </button>
      </div>
    </div>
    """
  end
end
