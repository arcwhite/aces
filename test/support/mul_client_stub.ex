defmodule Aces.MUL.ClientStub do
  @moduledoc """
  Test stub for `Aces.MUL.Client`, wired in via `config :aces, Aces.MUL, client: __MODULE__`.

  Tests set the next `fetch_units/1` response via `stub_fetch_units/1`; the value
  is stored in the process dictionary so parallel tests don't collide (mix tasks
  invoked inline share the caller's process).
  """

  @doc "Set the response `fetch_units/1` will return for the current process."
  def stub_fetch_units(response) do
    Process.put(:mul_client_stub_fetch_units, response)
    :ok
  end

  @doc "Clear any stubbed response (falls back to an empty successful list)."
  def clear do
    Process.delete(:mul_client_stub_fetch_units)
    :ok
  end

  @doc false
  def fetch_units(_filters \\ %{}) do
    Process.get(:mul_client_stub_fetch_units, {:ok, []})
  end
end
