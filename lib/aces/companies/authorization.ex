defmodule Aces.Companies.Authorization do
  @moduledoc """
  Authorization policies for company access control
  """

  alias Aces.Accounts.User
  alias Aces.Companies.Company
  alias Aces.Companies

  @doc """
  Check if a user can perform an action on a company

  ## Examples

      iex> can?(:view_company, user, company)
      true

      iex> can?(:edit_company, user, company)
      false
  """
  def can?(action, user, resource)

  # Anyone can view the companies index
  def can?(:list_companies, %User{}, nil), do: true

  # Anyone can create a company
  def can?(:create_company, %User{}, nil), do: true

  # View company - any member can view
  def can?(:view_company, %User{} = user, %Company{} = company) do
    has_role?(user, company, ["owner", "editor", "viewer"])
  end

  # Edit company - owner and editor can edit
  def can?(:edit_company, %User{} = user, %Company{} = company) do
    has_role?(user, company, ["owner", "editor"])
  end

  # Delete company - only owner can delete
  def can?(:delete_company, %User{} = user, %Company{} = company) do
    has_role?(user, company, ["owner"])
  end

  # Manage members - only owner can manage members
  def can?(:manage_members, %User{} = user, %Company{} = company) do
    has_role?(user, company, ["owner"])
  end

  # Add units - owner and editor can add units
  def can?(:add_units, %User{} = user, %Company{} = company) do
    has_role?(user, company, ["owner", "editor"])
  end

  # Remove units - owner and editor can remove units
  def can?(:remove_units, %User{} = user, %Company{} = company) do
    has_role?(user, company, ["owner", "editor"])
  end

  # Default deny
  def can?(_, _, _), do: false

  ## Private Helpers

  defp has_role?(%User{} = user, %Company{} = company, allowed_roles) do
    case Companies.get_user_role(company, user) do
      nil -> false
      role -> role in allowed_roles
    end
  end
end
