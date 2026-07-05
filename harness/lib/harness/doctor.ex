defmodule Harness.Doctor do
  @moduledoc """
  Environment checks, as data. `mix harness.doctor` prints them all;
  `Harness.BootCheck` runs the boot-critical subset before the supervision
  tree starts.

  Each check returns `{:ok, info}`, `{:warn, message}` or `{:error, message}`.
  """

  alias Harness.Secrets

  defmodule Check do
    @enforce_keys [:id, :label, :boot, :run]
    defstruct [:id, :label, :boot, :run]
    # boot: :critical — failure always refuses boot (billing trap)
    #       :required — failure refuses boot at :strict, warns at :warn
    #       :none     — doctor-only (e.g. network checks)
  end

  def checks do
    [
      %Check{
        id: :anthropic_env,
        label: "ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN unset",
        boot: :critical,
        run: &check_anthropic_env/0
      },
      %Check{
        id: :claude_version,
        label: "claude CLI present",
        boot: :required,
        run: &check_claude_version/0
      },
      %Check{
        id: :claude_auth,
        label: "claude subscription auth (Max, OAuth)",
        boot: :required,
        run: &check_claude_auth/0
      },
      %Check{
        id: :harness_home,
        label: "~/.harness writable",
        boot: :required,
        run: fn -> check_writable_dir(harness_home()) end
      },
      %Check{
        id: :workspaces,
        label: "workspaces/ writable",
        boot: :required,
        run: fn -> check_writable_dir(Application.fetch_env!(:harness, :workspaces_dir)) end
      },
      %Check{
        id: :policy,
        label: "ops/policy.yaml parses",
        boot: :required,
        run: &check_policy/0
      },
      %Check{
        id: :github_pat,
        label: "GitHub PAT in Keychain",
        # spec §6 lists PAT validity among boot assertions; the Keychain
        # presence check is network-free so it can safely gate boot
        boot: :required,
        run: &check_github_pat/0
      },
      %Check{
        id: :github_api,
        label: "GitHub API reachable with PAT",
        boot: :none,
        run: &check_github_api/0
      },
      %Check{
        id: :launchd,
        label: "launchd agent",
        boot: :none,
        run: &check_launchd/0
      },
      %Check{
        id: :usage_schema,
        label: "usage endpoint schema (schema drift?)",
        boot: :none,
        run: &check_usage_schema/0
      }
    ]
  end

  @doc "Run every check. Returns `[{check, result}]`."
  def run_all, do: Enum.map(checks(), &{&1, &1.run.()})

  @doc "Run only checks relevant at boot for the given level."
  def run_boot(level) when level in [:warn, :strict] do
    checks()
    |> Enum.reject(&(&1.boot == :none))
    |> Enum.map(&{&1, &1.run.()})
  end

  # -- individual checks ------------------------------------------------------

  defp check_anthropic_env do
    set = Enum.filter(["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"], &System.get_env/1)

    case set do
      [] ->
        {:ok, "unset"}

      vars ->
        {:error,
         "#{Enum.join(vars, ", ")} present — headless claude would silently bill the API " <>
           "instead of the Max subscription. Unset before starting the harness."}
    end
  end

  defp check_claude_version do
    case System.cmd("claude", ["--version"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, "claude --version exited #{code}: #{String.trim(output)}"}
    end
  rescue
    ErlangError -> {:error, "claude executable not found on PATH"}
  end

  defp check_claude_auth do
    case System.cmd("claude", ["auth", "status", "--json"], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"loggedIn" => true, "authMethod" => "claude.ai", "subscriptionType" => sub}}
          when is_binary(sub) ->
            if String.contains?(sub, "max") do
              {:ok, "logged in, subscription: #{sub}"}
            else
              {:warn, "logged in but subscription is #{inspect(sub)}, expected max"}
            end

          {:ok, %{"loggedIn" => true} = status} ->
            {:warn, "logged in via #{inspect(status["authMethod"])} — expected claude.ai OAuth"}

          {:ok, _} ->
            {:error, "not logged in — run `claude auth login`"}

          {:error, _} ->
            {:error, "could not parse `claude auth status --json`: #{String.trim(output)}"}
        end

      {output, _code} ->
        {:error, "claude auth status failed: #{String.trim(output)}"}
    end
  rescue
    ErlangError -> {:error, "claude executable not found on PATH"}
  end

  defp check_writable_dir(dir) do
    probe = Path.join(dir, ".harness-write-probe")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(probe, "ok"),
         :ok <- File.rm(probe) do
      {:ok, dir}
    else
      {:error, reason} -> {:error, "#{dir} not writable: #{inspect(reason)}"}
    end
  end

  defp check_policy do
    path = Application.fetch_env!(:harness, :policy_path)

    with true <- File.exists?(path) || :missing,
         {:ok, raw} <- YamlElixir.read_from_file(path),
         {:ok, policy} <- Harness.Policy.Schema.parse(raw) do
      {:ok, "mode: #{policy.mode}, repos: #{length(policy.github.repos)}"}
    else
      :missing -> {:error, "#{path} not found — cp ops/policy.example.yaml ops/policy.yaml"}
      {:error, errors} when is_list(errors) -> {:error, Enum.join(errors, "; ")}
      {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
    end
  end

  defp check_github_pat do
    case Secrets.github_pat() do
      {:ok, _pat} -> {:ok, "service #{Secrets.pat_service()}"}
      {:error, :not_found} -> {:error, "no PAT in Keychain — run `mix harness.setup`"}
    end
  end

  defp check_github_api do
    with {:ok, pat} <- Secrets.github_pat() do
      {:ok, _} = Application.ensure_all_started(:req)

      case Req.get(
             url: "https://api.github.com/user",
             headers: [
               {"authorization", "Bearer #{pat}"},
               {"x-github-api-version", "2022-11-28"}
             ],
             retry: false
           ) do
        {:ok, %{status: 200, body: %{"login" => login}} = resp} ->
          {:ok, "authenticated as #{login}#{pat_expiry_note(resp)}"}

        {:ok, %{status: 401}} ->
          {:error, "PAT rejected (401) — expired or revoked; rotate via `mix harness.setup`"}

        {:ok, %{status: status}} ->
          {:warn, "GET /user returned #{status}"}

        {:error, reason} ->
          {:warn, "GitHub unreachable: #{inspect(reason)}"}
      end
    else
      {:error, :not_found} -> {:warn, "skipped — no PAT in Keychain"}
    end
  end

  defp pat_expiry_note(resp) do
    with [raw | _] <- Req.Response.get_header(resp, "github-authentication-token-expiration"),
         {:ok, expiry, _} <- DateTime.from_iso8601(normalize_expiry(raw)) do
      days = DateTime.diff(expiry, DateTime.utc_now(), :day)
      if days <= 14, do: " — PAT EXPIRES IN #{days} DAYS", else: ""
    else
      _ -> ""
    end
  end

  # header arrives as "2027-07-04 00:00:00 UTC" or ISO8601 depending on era
  defp normalize_expiry(raw) do
    raw |> String.replace(" UTC", "Z") |> String.replace(" ", "T")
  end

  @drift_window 3

  defp check_usage_schema do
    case Harness.Usage.health() do
      :schema_drift ->
        {:warn,
         "Last #{@drift_window} oauth_api samples all parsed nil utilization — " <>
           "the claude.ai usage endpoint schema may have changed. " <>
           "Inspect recent usage_samples.raw rows and update SubscriptionPool.parse/1."}

      :stale ->
        {:warn, "No fresh usage sample — poller may be paused or endpoint unreachable"}

      :ok ->
        {:ok, "fresh sample, utilization readable"}
    end
  end

  defp check_launchd do
    case System.cmd("launchctl", ["print", "gui/#{uid()}/com.nyel.harness"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        state =
          case Regex.run(~r/state = (\w+)/, output) do
            [_, state] -> state
            _ -> "loaded"
          end

        {:ok, "installed, state: #{state}"}

      {_output, _} ->
        {:warn, "not installed — `mix harness.install` for always-on operation"}
    end
  end

  defp uid do
    {uid, 0} = System.cmd("id", ["-u"])
    String.trim(uid)
  end

  defp harness_home, do: Application.fetch_env!(:harness, :harness_home)
end
