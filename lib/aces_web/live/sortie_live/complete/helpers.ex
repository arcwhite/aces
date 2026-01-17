defmodule AcesWeb.SortieLive.Complete.Helpers do
  @moduledoc """
  Shared helpers for sortie completion wizard steps.
  """

  use AcesWeb, :verified_routes

  @step_order ["outcome", "damage", "costs", "pilots", "spend_sp", "summary"]

  @doc """
  Returns the ordered list of wizard steps.
  """
  def step_order, do: @step_order

  @doc """
  Returns the index of a step (0-based).
  """
  def step_index(step), do: Enum.find_index(@step_order, &(&1 == step))

  @doc """
  Checks if navigating to `requested_step` is allowed from `current_step`.

  Navigation is allowed if:
  - Going to the current step
  - Going backwards to a previous step
  - Going forward by exactly one step
  """
  def can_navigate_to?(current_step, requested_step) do
    current_idx = step_index(current_step)
    requested_idx = step_index(requested_step)

    cond do
      current_idx == nil or requested_idx == nil -> false
      requested_idx <= current_idx -> true  # Can go back or stay
      requested_idx == current_idx + 1 -> true  # Can go forward one step
      true -> false
    end
  end

  @doc """
  Validates that the sortie can be accessed at the given step.
  Returns :ok or {:error, message, redirect_path}.
  """
  def validate_step_access(sortie, requested_step) do
    cond do
      sortie.status != "finalizing" ->
        {:error, "Sortie must be in finalizing state",
         ~p"/companies/#{sortie.campaign.company_id}/campaigns/#{sortie.campaign_id}/sorties/#{sortie.id}"}

      not can_navigate_to?(sortie.finalization_step, requested_step) ->
        {:error, "Please complete the previous step first",
         ~p"/companies/#{sortie.campaign.company_id}/campaigns/#{sortie.campaign_id}/sorties/#{sortie.id}/complete/#{sortie.finalization_step}"}

      true ->
        :ok
    end
  end
end
