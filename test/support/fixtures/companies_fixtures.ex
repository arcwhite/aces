defmodule Aces.CompaniesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Aces.Companies` context.
  """

  alias Aces.Companies
  alias Aces.AccountsFixtures

  def unique_company_name, do: "Company #{System.unique_integer()}"

  def valid_company_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_company_name(),
      description: "A test mercenary company",
      warchest_balance: 1000
    })
  end

  def company_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    user = Map.get(attrs, :user) || AccountsFixtures.user_fixture()
    attrs = Map.delete(attrs, :user)

    {:ok, company} =
      attrs
      |> valid_company_attributes()
      |> (&Companies.create_company(&1, user)).()

    company
  end

  def company_with_members_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    owner = Map.get(attrs, :owner) || AccountsFixtures.user_fixture()
    editor = Map.get(attrs, :editor) || AccountsFixtures.user_fixture()
    viewer = Map.get(attrs, :viewer) || AccountsFixtures.user_fixture()

    company = company_fixture(Map.put(attrs, :user, owner))

    {:ok, _} = Companies.add_member(company, editor, "editor")
    {:ok, _} = Companies.add_member(company, viewer, "viewer")

    company = Companies.get_company!(company.id)
    %{company: company, owner: owner, editor: editor, viewer: viewer}
  end

  def valid_master_unit_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      mul_id: System.unique_integer([:positive]),
      name: "Atlas",
      variant: "AS7-D",
      unit_type: "battlemech",
      point_value: 48,
      tonnage: 100
    })
  end

  def master_unit_fixture(attrs \\ %{}) do
    {:ok, master_unit} =
      attrs
      |> valid_master_unit_attributes()
      |> (&Aces.Repo.insert(struct(Aces.Units.MasterUnit, &1))).()

    master_unit
  end

  def company_unit_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    company = Map.get(attrs, :company) || company_fixture()
    master_unit = Map.get(attrs, :master_unit) || master_unit_fixture()

    {:ok, company_unit} =
      Companies.add_unit_to_company(company, master_unit.mul_id, %{
        custom_name: Map.get(attrs, :custom_name),
        purchase_cost_sp: Map.get(attrs, :purchase_cost_sp, 1920)
      })

    # Reload to get the master_unit association
    Aces.Repo.preload(company_unit, :master_unit, force: true)
  end
end
