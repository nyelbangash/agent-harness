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
      }
    ] ++
      github_api_checks() ++
      github_project_checks() ++
      [
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

  # One reachability check per owner configured in ops/policy.yaml — a
  # missing/expired org token is a named red line, not a mysterious 404
  # mid-pipeline. `boot: :none` (see boot_check.ex): network checks never
  # gate boot, so an expired org PAT can't crash-loop the daemon.
  defp github_api_checks do
    for owner <- configured_owners() do
      %Check{
        id: :"github_api_#{owner}",
        label: "GitHub API reachable (#{owner})",
        boot: :none,
        run: fn -> check_github_api(owner) end
      }
    end
  end

  # One reachability + Projects-scope check per {owner, number} configured
  # under `github.projects` — a missing "Projects: read" scope should be a
  # named red line in `mix harness.doctor`, not a silently empty item list.
  defp github_project_checks do
    for {owner, number} <- configured_projects() do
      %Check{
        id: :"github_project_#{owner}_#{number}",
        label: "GitHub Projects v2 reachable (#{owner}/#{number})",
        boot: :none,
        run: fn -> check_github_project(owner, number) end
      }
    end
  end

  defp configured_projects do
    case configured_policy() do
      {:ok, policy} -> Enum.map(policy.github.projects, &{&1.owner, &1.number})
      _ -> []
    end
  end

  defp check_github_project(owner, number) do
    case Harness.GitHub.Client.list_project_items(owner, number) do
      {:ok, items} ->
        {:ok, "#{length(items)} items"}

      {:error, {:graphql_errors, errors}} ->
        if Enum.any?(errors, &scope_error?/1) do
          {:error,
           "Projects scope missing for #{owner} — add \"Projects: read\" to the fine-grained " <>
             "PAT (`mix harness.setup #{owner}`)"}
        else
          {:warn, "GraphQL errors: #{inspect(errors)}"}
        end

      {:error, reason} ->
        {:warn, "GitHub Projects unreachable: #{inspect(reason)}"}
    end
  end

  defp scope_error?(%{"type" => "FORBIDDEN"}), do: true

  defp scope_error?(%{"message" => message}) when is_binary(message) do
    String.contains?(message, "does not have permission") or
      String.contains?(message, "not accessible by personal access token") or
      String.contains?(message, "scope") or String.contains?(message, "projectsV2")
  end

  defp scope_error?(_), do: false

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
    case configured_policy() do
      {:ok, policy} ->
        {:ok, "mode: #{policy.mode}, repos: #{length(policy.github.repos)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  # `Harness.BootCheck.assert!/0` runs `checks/0` before the supervision
  # tree starts, so this re-parses ops/policy.yaml directly rather than
  # calling `Harness.Policy.get()` — the `:persistent_term` it reads from
  # isn't populated yet.
  defp configured_policy do
    path = Application.fetch_env!(:harness, :policy_path)

    with true <- File.exists?(path) || :missing,
         {:ok, raw} <- YamlElixir.read_from_file(path),
         {:ok, policy} <- Harness.Policy.Schema.parse(raw) do
      {:ok, policy}
    else
      :missing -> {:error, "#{path} not found — cp ops/policy.example.yaml ops/policy.yaml"}
      {:error, errors} when is_list(errors) -> {:error, Enum.join(errors, "; ")}
      {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
    end
  end

  defp configured_repo_names do
    case configured_policy() do
      {:ok, policy} -> {:ok, Enum.map(policy.github.repos, & &1.name)}
      {:error, message} -> {:error, message}
    end
  end

  # A fresh, not-yet-onboarded install (or an unparseable policy file) still
  # gets one meaningful GitHub API check instead of an empty check list.
  defp configured_owners do
    case configured_repo_names() do
      {:ok, [_ | _] = repo_names} -> repo_names |> Enum.map(&Secrets.owner_of/1) |> Enum.uniq()
      _ -> ["default"]
    end
  end

  defp check_github_pat do
    case Secrets.github_pat() do
      {:ok, _pat} -> {:ok, "service #{Secrets.pat_service()}"}
      {:error, :not_found} -> {:error, "no PAT in Keychain — run `mix harness.setup`"}
    end
  end

  defp check_github_api(owner) do
    with {:ok, pat} <- Secrets.github_pat_for_owner(owner) do
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
          {:error,
           "PAT rejected (401) for #{owner} — expired or revoked; rotate via " <>
             "`mix harness.setup #{owner}`"}

        {:ok, %{status: status}} ->
          {:warn, "GET /user returned #{status}"}

        {:error, reason} ->
          {:warn, "GitHub unreachable: #{inspect(reason)}"}
      end
    else
      {:error, :not_found} -> {:warn, "skipped — no PAT in Keychain for #{owner}"}
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
    # This inspects live usage samples, so it needs the running app (policy
    # server + Repo). `mix harness.doctor` runs pre-boot (see the
    # configured_policy/0 note), so if the supervision tree is down there is
    # nothing to inspect — report that instead of crashing on the empty
    # :persistent_term / unstarted Repo.
    if Process.whereis(Harness.Policy.Server) == nil do
      {:ok, "skipped — run against the running harness to check usage drift"}
    else
      usage_health_result()
    end
  end

  defp usage_health_result do
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
