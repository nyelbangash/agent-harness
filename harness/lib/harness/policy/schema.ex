defmodule Harness.Policy.Schema do
  @moduledoc """
  Parsed, validated form of `ops/policy.yaml`.

  Parsing is strict about the fields workers gate on (mode, thresholds,
  budgets) and lenient about the rest: unknown keys are ignored so the yaml
  can grow ahead of the code, but a missing/invalid required field fails the
  whole parse — `Policy.Server` then keeps the previous good policy.
  """

  defmodule Models do
    defstruct triage: "sonnet",
              implement: "sonnet",
              plan: "sonnet",
              ideate: "sonnet",
              critique: "opus",
              escalation: "opus",
              respond: "sonnet"
  end

  defmodule Schedule do
    defstruct full_auto_windows: [],
              ideation_windows: [],
              max_ideation_sessions_per_week: 3
  end

  defmodule Budgets do
    defstruct opus_hours_weekly_cap: 18,
              overflow_usd_weekly_cap: 25,
              implement_max_turns: 60,
              ideate_iteration_max_turns: 25,
              triage_max_turns: 12,
              plan_max_turns: 40,
              review_max_turns: 20,
              compose_max_turns: 20
  end

  defmodule UtilizationGates do
    defstruct poll_minutes: 10,
              full_auto_below: 0.60,
              defer_ideation_above: 0.60,
              plan_only_above: 0.80,
              pause_above: 0.90
  end

  defmodule Triage do
    defstruct auto_threshold: 0.75, low_confidence_floor: 0.4
  end

  defmodule Plan do
    defstruct post_to_issue: false
  end

  defmodule Implement do
    defstruct max_fix_cycles: 2
  end

  defmodule Ideate do
    defstruct critique_every: 5, default_budget_minutes: 180
  end

  defmodule Review do
    defstruct max_rounds: 1,
              confidence_floor: 0.7,
              model: "opus",
              fix_model: "sonnet",
              rebase_max_attempts: 2
  end

  defmodule GitHub do
    defstruct repos: [], poll_minutes: 2
  end

  defmodule Notify do
    defstruct macos: true, ntfy_topic: nil, budget_warn_fraction: 0.80
  end

  defmodule Repo do
    @enforce_keys [:name]
    defstruct [:name, :test_command, :lint_command, :typecheck_command]
  end

  defmodule Manager do
    defstruct enabled: true,
              poll_minutes: 5,
              authority: "tier0",
              loop_triage_threshold: 5,
              loop_window_minutes: 30,
              stall_minutes: 10,
              ghost_job_grace_seconds: 120,
              telemetry_silence_samples: 3,
              review_model: nil,
              review_every_hours: 24
  end

  defstruct mode: :plan_only,
            models: nil,
            schedule: nil,
            budgets: nil,
            utilization_gates: nil,
            triage: nil,
            plan: nil,
            implement: nil,
            ideate: nil,
            review: nil,
            github: nil,
            notify: nil,
            billing_model: :subscription_pool,
            calendar_notes: [],
            manager: nil

  @type t :: %__MODULE__{}

  @modes ~w(plan_only full_auto paused)
  @billing_models ~w(subscription_pool sdk_credit)

  @spec parse(map()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(raw) when is_map(raw) do
    with {:ok, mode} <- enum(raw, "mode", @modes),
         {:ok, billing} <- enum(raw, "billing_model", @billing_models),
         {:ok, schedule} <- parse_schedule(raw["schedule"] || %{}),
         {:ok, github} <- parse_github(raw["github"] || %{}),
         {:ok, gates} <- parse_gates(raw["utilization_gates"] || %{}),
         {:ok, budgets} <- parse_budgets(raw["budgets"] || %{}),
         {:ok, triage} <- parse_triage(raw["triage"] || %{}) do
      {:ok,
       %__MODULE__{
         mode: mode,
         models: struct_from(Models, raw["models"]),
         schedule: schedule,
         budgets: budgets,
         utilization_gates: gates,
         triage: triage,
         plan: struct_from(Plan, raw["plan"]),
         implement: struct_from(Implement, raw["implement"]),
         ideate: struct_from(Ideate, raw["ideate"]),
         review: struct_from(Review, raw["review"]),
         github: github,
         notify: struct_from(Notify, raw["notify"]),
         billing_model: billing,
         calendar_notes: List.wrap(raw["calendar_notes"]) |> Enum.map(&to_string/1),
         manager: struct_from(Manager, raw["manager"])
       }}
    end
  end

  def parse(_), do: {:error, ["policy.yaml did not parse to a map"]}

  defp enum(raw, key, allowed) do
    value = raw[key]

    if is_binary(value) and value in allowed do
      {:ok, String.to_atom(value)}
    else
      {:error, ["#{key}: expected one of #{Enum.join(allowed, " | ")}, got #{inspect(value)}"]}
    end
  end

  defp struct_from(mod, nil), do: struct(mod)

  defp struct_from(mod, map) when is_map(map) do
    known = struct(mod) |> Map.from_struct() |> Map.keys()

    fields =
      for key <- known,
          value = map[Atom.to_string(key)],
          not is_nil(value),
          into: %{},
          do: {key, value}

    struct(mod, fields)
  end

  defp parse_schedule(map) when is_map(map) do
    with {:ok, full_auto} <- windows(map["full_auto_windows"], "schedule.full_auto_windows"),
         {:ok, ideation} <- windows(map["ideation_windows"], "schedule.ideation_windows") do
      {:ok,
       %Schedule{
         full_auto_windows: full_auto,
         ideation_windows: ideation,
         max_ideation_sessions_per_week: map["max_ideation_sessions_per_week"] || 3
       }}
    end
  end

  defp parse_schedule(_), do: {:error, ["schedule: expected a map"]}

  # "20:00-06:00" -> {~T[20:00:00], ~T[06:00:00]} (wrapping windows allowed)
  defp windows(nil, _key), do: {:ok, []}

  defp windows(list, key) when is_list(list) do
    parsed = Enum.map(list, &parse_window/1)

    case Enum.filter(parsed, &match?(:error, &1)) do
      [] -> {:ok, Enum.map(parsed, fn {:ok, w} -> w end)}
      _ -> {:error, ["#{key}: expected entries like \"20:00-06:00\", got #{inspect(list)}"]}
    end
  end

  defp windows(other, key), do: {:error, ["#{key}: expected a list, got #{inspect(other)}"]}

  defp parse_window(<<from::binary-size(5), "-", to::binary-size(5)>>) do
    with {:ok, from_t} <- Time.from_iso8601(from <> ":00"),
         {:ok, to_t} <- Time.from_iso8601(to <> ":00") do
      {:ok, {from_t, to_t}}
    else
      _ -> :error
    end
  end

  defp parse_window(_), do: :error

  defp parse_github(map) when is_map(map) do
    repos = List.wrap(map["repos"])
    parsed = Enum.map(repos, &parse_repo/1)

    case Enum.filter(parsed, &match?(:error, &1)) do
      [] ->
        {:ok,
         %GitHub{
           repos: Enum.map(parsed, fn {:ok, r} -> r end),
           poll_minutes: map["poll_minutes"] || 2
         }}

      _ ->
        {:error, ["github.repos: entries must be \"owner/name\" or {name:, test_command:}"]}
    end
  end

  defp parse_github(_), do: {:error, ["github: expected a map"]}

  defp parse_repo(name) when is_binary(name) do
    if name =~ ~r{\A[\w.-]+/[\w.-]+\z}, do: {:ok, %Repo{name: name}}, else: :error
  end

  defp parse_repo(%{"name" => name} = map) when is_binary(name) do
    case parse_repo(name) do
      {:ok, repo} ->
        {:ok,
         %{
           repo
           | test_command: map["test_command"],
             lint_command: map["lint_command"],
             typecheck_command: map["typecheck_command"]
         }}

      :error ->
        :error
    end
  end

  defp parse_repo(_), do: :error

  defp parse_gates(map) when is_map(map) do
    gates = struct_from(UtilizationGates, map)

    thresholds = [
      gates.full_auto_below,
      gates.defer_ideation_above,
      gates.plan_only_above,
      gates.pause_above
    ]

    if Enum.all?(thresholds, &(is_number(&1) and &1 >= 0 and &1 <= 1)) and
         is_integer(gates.poll_minutes) and gates.poll_minutes > 0 do
      {:ok, gates}
    else
      {:error, ["utilization_gates: thresholds must be 0..1 and poll_minutes a positive integer"]}
    end
  end

  defp parse_gates(_), do: {:error, ["utilization_gates: expected a map"]}

  defp parse_budgets(map) when is_map(map) do
    budgets = struct_from(Budgets, map)
    values = budgets |> Map.from_struct() |> Map.values()

    if Enum.all?(values, &(is_number(&1) and &1 > 0)) do
      {:ok, budgets}
    else
      {:error, ["budgets: all values must be positive numbers"]}
    end
  end

  defp parse_budgets(_), do: {:error, ["budgets: expected a map"]}

  defp parse_triage(map) when is_map(map) do
    triage = struct_from(Triage, map)

    if is_number(triage.auto_threshold) and triage.auto_threshold >= 0 and
         triage.auto_threshold <= 1 and
         is_number(triage.low_confidence_floor) and triage.low_confidence_floor >= 0 and
         triage.low_confidence_floor <= 1 do
      {:ok, triage}
    else
      {:error, ["triage: auto_threshold and low_confidence_floor must be 0..1"]}
    end
  end

  defp parse_triage(_), do: {:error, ["triage: expected a map"]}
end
