defmodule FuckingDave.Repo do
  use Ecto.Repo,
    otp_app: :fucking_dave,
    adapter: Ecto.Adapters.Postgres
end
