# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :harness,
  ecto_repos: [Harness.Repo],
  generators: [timestamp_type: :utc_datetime]

# .log/.diff/.patch have no entry in MIME's default type list, but
# ComposeLive/IdeationLive's attachment uploads accept them as plain text.
# MIME's :types config fully replaces the extension list for a redefined
# type, so the default "txt"/"text" extensions must be repeated here.
config :mime, :types, %{
  "text/plain" => ["txt", "text", "log", "diff", "patch"]
}

# Repo root of this project (ProjectEx) — ops/, workspaces/ live one level above the app
config :harness, :project_root, Path.expand("../..", __DIR__)
config :harness, :boot_check_level, :strict
config :harness, :policy_path, Path.expand("../../ops/policy.yaml", __DIR__)
config :harness, :prompts_dir, Path.expand("../../ops/prompts", __DIR__)
config :harness, :workspaces_dir, Path.expand("../../workspaces", __DIR__)
config :harness, :harness_home, Path.expand("~/.harness")

# SQLite: DEFERRED transactions that upgrade to writes return SQLITE_BUSY
# immediately (busy_timeout is not consulted), so run write transactions
# IMMEDIATE from the start. Keep the pool small — SQLite has one writer.
config :harness, Harness.Repo,
  default_transaction_mode: :immediate,
  pool_size: 5,
  busy_timeout: 5_000

config :harness, Oban,
  engine: Oban.Engines.Lite,
  repo: Harness.Repo,
  queues: [triage: 2, plan: 1, implement: 1, review: 1, ideate: 1, compose: 1, ops: 2, respond: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    Oban.Plugins.Lifeline,
    # Workers self-throttle against policy.yaml intervals (poll_minutes is
    # hot-reloadable; Oban cron is fixed at boot), so cron fires every minute
    # and the workers early-exit when not due.
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Harness.GitHub.PollWorker},
       {"* * * * *", Harness.Usage.PollWorker},
       {"* * * * *", Harness.Janitor},
       {"* * * * *", Harness.Manager.Worker},
       {"0 7 * * *", Harness.Briefing.Worker}
     ]}
  ]

# Configure the endpoint
config :harness, HarnessWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HarnessWeb.ErrorHTML, json: HarnessWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Harness.PubSub,
  live_view: [signing_salt: "tRtzrWLQ"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  harness: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  harness: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
