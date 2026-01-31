defmodule Aces.ChangesetHelpers do
  @moduledoc """
  Shared helper functions for working with Ecto changesets.
  """

  @doc """
  Formats changeset errors into a human-readable string.

  Takes an Ecto.Changeset and returns a comma-separated string
  of "field: message" pairs.

  ## Examples

      iex> changeset = %Ecto.Changeset{errors: [name: {"can't be blank", []}]}
      iex> format_errors(changeset)
      "name: can't be blank"

      iex> changeset = %Ecto.Changeset{errors: [name: {"can't be blank", []}, email: {"is invalid", []}]}
      iex> format_errors(changeset)
      "name: can't be blank, email: is invalid"
  """
  @spec format_errors(Ecto.Changeset.t()) :: String.t()
  def format_errors(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end
end
