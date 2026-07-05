defmodule HarnessWeb.HealthController do
  use HarnessWeb, :controller

  def index(conn, _params) do
    case Harness.Health.check() do
      {:ok, body} -> json(conn, body)
      {:error, body} -> conn |> put_status(503) |> json(body)
    end
  end
end
