defmodule Harness.GitHub.Triage do
  @moduledoc """
  The triage JSON contract and the §4.2 routing rules.

  `validate/1` re-checks the CLI's schema-validated `structured_output` in
  Elixir (belt and braces — the contract is enforced at both layers).
  `route/2` is pure policy: the model proposes, these rules dispose.
  """

  defmodule Decision do
    @enforce_keys [:route, :confidence, :reasoning, :estimated_scope, :risk_flags]
    defstruct [:route, :confidence, :reasoning, :estimated_scope, :risk_flags]

    @type t :: %__MODULE__{}
  end

  @routes ~w(auto plan skip)
  @scopes ~w(xs s m l)
  @auto_scopes ~w(xs s)
  @required_keys ~w(route confidence reasoning estimated_scope risk_flags)

  @doc "JSON Schema handed to `--json-schema` (CLI-side enforcement)."
  def schema_json do
    Jason.encode!(%{
      type: "object",
      properties: %{
        route: %{type: "string", enum: @routes},
        confidence: %{type: "number", minimum: 0, maximum: 1},
        reasoning: %{type: "string"},
        estimated_scope: %{type: "string", enum: @scopes},
        risk_flags: %{type: "array", items: %{type: "string"}}
      },
      required: @required_keys,
      additionalProperties: false
    })
  end

  @doc "Elixir-side re-validation of the structured output."
  @spec validate(term()) :: {:ok, Decision.t()} | {:error, [String.t()]}
  def validate(%{} = raw) do
    errors =
      List.flatten([
        missing_keys(raw),
        unknown_keys(raw),
        check(raw, "route", &(&1 in @routes), "must be one of #{Enum.join(@routes, "|")}"),
        check(
          raw,
          "confidence",
          &(is_number(&1) and &1 >= 0 and &1 <= 1),
          "must be a number in 0..1"
        ),
        check(raw, "reasoning", &is_binary/1, "must be a string"),
        check(
          raw,
          "estimated_scope",
          &(&1 in @scopes),
          "must be one of #{Enum.join(@scopes, "|")}"
        ),
        check(
          raw,
          "risk_flags",
          &(is_list(&1) and Enum.all?(&1, fn f -> is_binary(f) end)),
          "must be a list of strings"
        )
      ])

    case errors do
      [] ->
        {:ok,
         %Decision{
           route: raw["route"],
           confidence: raw["confidence"] / 1,
           reasoning: raw["reasoning"],
           estimated_scope: raw["estimated_scope"],
           risk_flags: raw["risk_flags"]
         }}

      errors ->
        {:error, errors}
    end
  end

  def validate(_other), do: {:error, ["structured output was not a JSON object"]}

  defp missing_keys(raw) do
    for key <- @required_keys, not Map.has_key?(raw, key), do: "#{key}: missing"
  end

  defp unknown_keys(raw) do
    for key <- Map.keys(raw), key not in @required_keys, do: "#{key}: unknown key"
  end

  defp check(raw, key, predicate, message) do
    cond do
      not Map.has_key?(raw, key) -> []
      predicate.(raw[key]) -> []
      true -> ["#{key}: #{message}"]
    end
  end

  @doc """
  §4.2 routing. Context:

    * `labels` — the issue's labels (`human-only` short-circuits to skip)
    * `auto_threshold` — `policy.triage.auto_threshold`
    * `test_command?` — the repo has a configured test command
    * `full_auto_active?` — mode is full_auto AND inside a full-auto window
      AND utilization allows it (`Policy.full_auto_active?/1`)
  """
  @spec route(Decision.t(), map()) :: {String.t(), String.t()}
  def route(%Decision{} = decision, ctx) do
    cond do
      "human-only" in ctx.labels ->
        {"skip", "human_only_label"}

      decision.route == "auto" ->
        route_auto(decision, ctx)

      decision.route == "skip" ->
        # spec-literal: only the human-only label skips; "anything else → plan"
        {"plan", "model_skip_demoted"}

      true ->
        {"plan", "proposed_plan"}
    end
  end

  defp route_auto(decision, ctx) do
    cond do
      decision.confidence < ctx.auto_threshold -> {"plan", "confidence_below_threshold"}
      decision.estimated_scope not in @auto_scopes -> {"plan", "scope_too_large"}
      decision.risk_flags != [] -> {"plan", "risk_flags_present"}
      not ctx.test_command? -> {"plan", "no_test_command"}
      not ctx.full_auto_active? -> {"plan", "mode_not_full_auto"}
      true -> {"auto", "all_gates_passed"}
    end
  end
end
