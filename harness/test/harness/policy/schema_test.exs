defmodule Harness.Policy.SchemaTest do
  use ExUnit.Case, async: true

  alias Harness.Policy.Schema

  defp base_raw do
    {:ok, raw} =
      Application.fetch_env!(:harness, :policy_path)
      |> YamlElixir.read_from_file()

    raw
  end

  test "parses the shipped ops/policy.yaml" do
    assert {:ok, policy} = Schema.parse(base_raw())

    assert policy.mode == :plan_only
    assert policy.billing_model == :subscription_pool
    assert policy.models.triage == "sonnet"
    assert policy.models.critique == "opus"
    assert policy.models.escalation == "opus"
    assert policy.schedule.full_auto_windows == [{~T[20:00:00], ~T[06:00:00]}]
    assert policy.schedule.ideation_windows == [{~T[21:00:00], ~T[02:00:00]}]
    assert policy.budgets.opus_hours_weekly_cap == 18
    assert policy.budgets.implement_max_turns == 60
    assert policy.budgets.triage_max_turns == 12
    assert policy.budgets.plan_max_turns == 40
    assert policy.utilization_gates.plan_only_above == 0.80
    assert policy.triage.auto_threshold == 0.75
    assert policy.triage.low_confidence_floor == 0.4
    assert policy.plan.post_to_issue == false
    assert policy.implement.max_fix_cycles == 2
    assert policy.github.repos == []
    assert policy.github.poll_minutes == 2
    assert [note] = policy.calendar_notes
    assert note =~ "2026-07-13"
  end

  test "rejects an unknown mode" do
    assert {:error, [error]} = Schema.parse(Map.put(base_raw(), "mode", "yolo"))
    assert error =~ "mode"
  end

  test "rejects an unknown billing model" do
    assert {:error, [error]} = Schema.parse(Map.put(base_raw(), "billing_model", "free"))
    assert error =~ "billing_model"
  end

  test "rejects malformed schedule windows" do
    raw = put_in(base_raw(), ["schedule", "full_auto_windows"], ["20:00"])
    assert {:error, [error]} = Schema.parse(raw)
    assert error =~ "full_auto_windows"
  end

  test "rejects out-of-range utilization thresholds" do
    raw = put_in(base_raw(), ["utilization_gates", "pause_above"], 9.0)
    assert {:error, [error]} = Schema.parse(raw)
    assert error =~ "utilization_gates"
  end

  test "rejects non-positive budgets" do
    raw = put_in(base_raw(), ["budgets", "plan_max_turns"], 0)
    assert {:error, [error]} = Schema.parse(raw)
    assert error =~ "budgets"
  end

  test "parses repos as plain names and as maps with test_command" do
    raw =
      put_in(base_raw(), ["github", "repos"], [
        "nyelbangash/sandbox",
        %{"name" => "nyelbangash/other", "test_command" => "mix test"}
      ])

    assert {:ok, policy} = Schema.parse(raw)
    assert [plain, with_cmd] = policy.github.repos
    assert plain.name == "nyelbangash/sandbox"
    assert plain.test_command == nil
    assert with_cmd.name == "nyelbangash/other"
    assert with_cmd.test_command == "mix test"
  end

  test "rejects malformed repo entries" do
    raw = put_in(base_raw(), ["github", "repos"], ["not-a-repo"])
    assert {:error, [error]} = Schema.parse(raw)
    assert error =~ "github.repos"
  end

  test "unknown keys are ignored so the yaml can grow ahead of the code" do
    assert {:ok, _} = Schema.parse(Map.put(base_raw(), "future_section", %{"x" => 1}))
  end
end
