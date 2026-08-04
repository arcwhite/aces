defmodule Mix.Tasks.SeedMasterUnitsTest do
  use Aces.DataCase

  import ExUnit.CaptureIO

  alias Aces.Units

  # The matrix seed path is only reachable on a real (non-dry) run: matrix_dry_run/2
  # never calls the client, so a dry run cannot catch a bad destructure of
  # Client.fetch_units/1's {:ok, {units, source}} contract. That is exactly how
  # `seed_combination/2` shipped a `{:ok, units}` match that crashed with
  # "protocol Enumerable not implemented for Tuple" on the first live combination.
  #
  # These tests run against the fixture-backed client (config/test.exs pins
  # :mul_client_source to :fixture), so they exercise the full seed path with no
  # network and no rate limiting.
  describe "--matrix (live seed path)" do
    test "seeds a single era/faction combination without raising" do
      assert Units.count_cached_units() == 0

      output =
        capture_io(fn ->
          Mix.Tasks.SeedMasterUnits.run([
            "--matrix",
            "--era",
            "ilclan",
            "--faction",
            "mercenary"
          ])
        end)

      # Reached the per-combination summary rather than blowing up mid-reduce.
      assert output =~ "Matrix seed"
      assert Units.count_cached_units() > 0
    end

    test "is idempotent across repeated runs of the same combination" do
      run = fn ->
        capture_io(fn ->
          Mix.Tasks.SeedMasterUnits.run([
            "--matrix",
            "--era",
            "ilclan",
            "--faction",
            "mercenary"
          ])
        end)
      end

      run.()
      after_first = Units.count_cached_units()

      run.()
      after_second = Units.count_cached_units()

      # create_or_update_master_unit/1 merges faction data per era rather than
      # inserting duplicate rows, so a re-run tops up availability in place.
      assert after_second == after_first
    end
  end
end
