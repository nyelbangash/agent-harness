defmodule Harness.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Harness.BootCheck.assert!()

    children = [
      HarnessWeb.Telemetry,
      Harness.Repo,
      {Ecto.Migrator, repos: Application.fetch_env!(:harness, :ecto_repos)},
      {DNSCluster, query: Application.get_env(:harness, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Harness.PubSub},
      Harness.Policy.Server,
      Harness.Policy.Watcher,
      {Oban, Application.fetch_env!(:harness, Oban)},
      # Start to serve requests, typically the last entry
      HarnessWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Harness.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HarnessWeb.Endpoint.config_change(changed, removed)
    :ok
  end

end
