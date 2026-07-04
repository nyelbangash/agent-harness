defmodule Harness.Repo do
  use Ecto.Repo,
    otp_app: :harness,
    adapter: Ecto.Adapters.SQLite3
end
