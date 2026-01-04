defmodule Aces.Companies.CompanyUnit do
  @moduledoc """
  Schema for units in a company's roster
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Aces.Companies.Company
  alias Aces.Units.MasterUnit

  @valid_statuses ~w(operational damaged destroyed salvaged)

  schema "company_units" do
    field :custom_name, :string
    field :status, :string, default: "operational"
    field :purchase_cost_sp, :integer, default: 0

    belongs_to :company, Company
    belongs_to :master_unit, MasterUnit

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(company_unit, attrs) do
    company_unit
    |> cast(attrs, [:company_id, :master_unit_id, :custom_name, :status, :purchase_cost_sp])
    |> validate_required([:company_id, :master_unit_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:purchase_cost_sp, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:master_unit_id)
  end

  @doc """
  Returns the list of valid statuses
  """
  def valid_statuses, do: @valid_statuses
end
