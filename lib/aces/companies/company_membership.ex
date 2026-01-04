defmodule Aces.Companies.CompanyMembership do
  @moduledoc """
  Join table for user access to companies with role-based permissions
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Accounts.User
  alias Aces.Companies.Company

  @valid_roles ~w(owner editor viewer)

  schema "company_memberships" do
    field :role, :string, default: "viewer"

    belongs_to :user, User
    belongs_to :company, Company

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :company_id, :role])
    |> validate_required([:user_id, :company_id, :role])
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint([:user_id, :company_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:company_id)
  end

  @doc """
  Returns the list of valid roles
  """
  def valid_roles, do: @valid_roles
end
