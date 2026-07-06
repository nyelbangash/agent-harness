import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :harness, Harness.Repo,
  database: Path.expand("../harness_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQLite has a single writer. Under the full suite's parallelism (max_cases
  # ~= 2x cores), async writers collide with the async: false LiveView tests
  # and a waiter can exhaust the default 5s, surfacing as intermittent
  # "Database busy". A longer test-only timeout absorbs the write bursts —
  # it only ever waits when genuinely contended, so the happy path is unchanged.
  busy_timeout: 30_000

config :harness, Oban, testing: :manual

config :harness, :runner, Harness.Runs.FakeRunner
config :harness, :notify_backend, Harness.Notify.TestBackend
config :harness, :boot_check_level, :skip
config :harness, :policy_path, Path.expand("../test/support/fixtures/policy.yaml", __DIR__)

# never touch the real ~/.harness, Keychain, or GitHub from tests
config :harness, :harness_home, Path.expand("../tmp/test_harness_home", __DIR__)
config :harness, :workspaces_dir, Path.expand("../tmp/test_workspaces", __DIR__)
config :harness, :github_pat, "test-pat"
config :harness, :claude_oauth_token, "test-oauth-token"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :harness, HarnessWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YLa7oY4cqR6ijKaW3SLs+58U2RHYMpnS7cDbAbZKjbpbxnlQjSVIFWR/GHkFYJya",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
