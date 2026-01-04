defmodule Aces.Companies.Company do
  @moduledoc """
  Schema for mercenary companies
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.{CompanyMembership, CompanyUnit}

  schema "companies" do
    field :name, :string
    field :description, :string
    field :warchest_balance, :integer, default: 0

    has_many :memberships, CompanyMembership
    has_many :users, through: [:memberships, :user]
    has_many :company_units, CompanyUnit

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(company, attrs) do
    company
    |> cast(attrs, [:name, :description, :warchest_balance])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_number(:warchest_balance, greater_than_or_equal_to: 0)
  end

  @doc """
  Changeset for creating a new company with default warchest
  """
  def creation_changeset(company, attrs) do
    changeset =
      company
      |> cast(attrs, [:name, :description, :warchest_balance])
      |> validate_required([:name])
      |> validate_length(:name, min: 1, max: 255)
      |> validate_length(:description, max: 2000)
      |> validate_number(:warchest_balance, greater_than_or_equal_to: 0)

    # Set default warchest_balance to 0 only if not provided
    case get_change(changeset, :warchest_balance) do
      nil -> put_change(changeset, :warchest_balance, 0)
      _ -> changeset
    end
  end
end
