defmodule Mix.Tasks.SeedMasterUnitsTest do
  use Aces.DataCase

  alias Aces.MUL.ClientStub
  alias Mix.Tasks.SeedMasterUnits

  setup do
    on_exit(&ClientStub.clear/0)
    :ok
  end

  describe "perform_seed/1" do
    # Matrix mode / seed_combination/2 aren't in this branch yet; this
    # exercises the equivalent client seam on the single-combination path —
    # a failing fetch returns :error, which run/1 translates to System.halt(1).
    test "returns :error when the MUL client fetch fails" do
      ClientStub.stub_fetch_units({:error, "boom"})

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert SeedMasterUnits.perform_seed(era: "ilclan", faction: "mercenary") == :error
        end)

      assert output =~ "Failed to fetch units from MUL API"
      assert output =~ "boom"
    end
  end
end
