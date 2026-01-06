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
    field :pv_budget, :integer, default: 400
    field :status, :string, default: "draft"

    has_many :memberships, CompanyMembership
    has_many :users, through: [:memberships, :user]
    has_many :company_units, CompanyUnit

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(company, attrs) do
    company
    |> cast(attrs, [:name, :description, :warchest_balance, :pv_budget, :status])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_number(:warchest_balance, greater_than_or_equal_to: 0)
    |> validate_number(:pv_budget, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, ["draft", "active"])
  end

  @doc """
  Changeset for creating a new company with default PV budget and warchest
  """
  def creation_changeset(company, attrs) do
    changeset =
      company
      |> cast(attrs, [:name, :description, :warchest_balance, :pv_budget])
      |> validate_required([:name])
      |> validate_length(:name, min: 1, max: 255)
      |> validate_length(:description, max: 2000)
      |> validate_number(:warchest_balance, greater_than_or_equal_to: 0)
      |> validate_number(:pv_budget, greater_than_or_equal_to: 0)

    changeset =
      # Set default warchest_balance to 0 only if not provided
      case get_change(changeset, :warchest_balance) do
        nil -> put_change(changeset, :warchest_balance, 0)
        _ -> changeset
      end

    changeset =
      # Set default pv_budget to 400 only if not provided
      case get_change(changeset, :pv_budget) do
        nil -> put_change(changeset, :pv_budget, 400)
        _ -> changeset
      end

    # Always start companies in draft status
    put_change(changeset, :status, "draft")
  end
end
