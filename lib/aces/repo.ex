defmodule Aces.Repo do
  use Ecto.Repo,
    otp_app: :aces,
    adapter: Ecto.Adapters.Postgres
end
