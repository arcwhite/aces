defmodule Aces.MUL do
  @moduledoc """
  MUL API integration namespace.

  `client/0` returns the configured client module (defaults to
  `Aces.MUL.Client`). Seed flows call MUL through this seam so tests can swap
  in a stub via `config :aces, Aces.MUL, client: SomeStub` without touching
  the network.
  """

  @client Application.compile_env(:aces, [__MODULE__, :client], Aces.MUL.Client)

  @doc "Returns the configured MUL client module."
  def client, do: @client
end
