defmodule Aces.ChangesetHelpersTest do
  use ExUnit.Case, async: true

  alias Aces.ChangesetHelpers

  describe "format_errors/1" do
    test "formats a single error" do
      changeset = %Ecto.Changeset{
        errors: [name: {"can't be blank", [validation: :required]}],
        valid?: false
      }

      assert ChangesetHelpers.format_errors(changeset) == "name: can't be blank"
    end

    test "formats multiple errors" do
      changeset = %Ecto.Changeset{
        errors: [
          name: {"can't be blank", [validation: :required]},
          email: {"is invalid", [validation: :format]}
        ],
        valid?: false
      }

      assert ChangesetHelpers.format_errors(changeset) == "name: can't be blank, email: is invalid"
    end

    test "returns empty string for changeset with no errors" do
      changeset = %Ecto.Changeset{errors: [], valid?: true}

      assert ChangesetHelpers.format_errors(changeset) == ""
    end

    test "handles error messages with interpolation options" do
      changeset = %Ecto.Changeset{
        errors: [
          amount: {"must be greater than %{number}", [validation: :number, kind: :greater_than, number: 0]}
        ],
        valid?: false
      }

      # Note: format_errors doesn't interpolate - it just takes the raw message
      assert ChangesetHelpers.format_errors(changeset) == "amount: must be greater than %{number}"
    end
  end
end
