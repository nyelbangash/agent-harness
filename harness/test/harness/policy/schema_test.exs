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
    assert policy.models.triage == "claude-sonnet-5"
    assert policy.models.critique == "claude-opus-4-8"
    assert policy.models.escalation == "claude-opus-4-8"
    assert policy.schedule.full_auto_windows == [{~T[20:00:00], ~T[06:00:00]}]
    assert policy.schedule.ideation_windows == [{~T[21:00:00], ~T[02:00:00]}]
    assert policy.budgets.opus_hours_weekly_cap == 18
    assert policy.utilization_gates.plan_only_above == 0.80
    assert policy.triage.auto_threshold == 0.75
    assert policy.triage.low_confidence_floor == 0.4
    assert policy.plan.post_to_issue == false
    assert policy.implement.max_fix_cycles == 2
    assert policy.review.rebase_max_attempts == 2
    assert policy.github.repos == []
    assert policy.github.poll_minutes == 2
    assert [note] = policy.calendar_notes
    assert note =~ "2026-07-13"
  end

  test "board.auto_clear_after_days defaults to 14 when absent" do
    assert {:ok, policy} = Schema.parse(base_raw())
    assert policy.board.auto_clear_after_days == 14
  end

  test "board.auto_clear_after_days honors an explicit override" do
    raw = Map.put(base_raw(), "board", %{"auto_clear_after_days" => 30})
    assert {:ok, policy} = Schema.parse(raw)
    assert policy.board.auto_clear_after_days == 30
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
    raw = put_in(base_raw(), ["budgets", "overflow_usd_weekly_cap"], 0)
    assert {:error, [error]} = Schema.parse(raw)
    assert error =~ "budgets"
  end

  test "parses repos as plain names and as maps with test_command" do
    raw =
      put_in(base_raw(), ["github", "repos"], [
        "nyelbangash/sandbox",
        %{
          "name" => "nyelbangash/other",
          "test_command" => "mix test",
          "playwright_command" => "npx playwright test"
        }
      ])

    assert {:ok, policy} = Schema.parse(raw)
    assert [plain, with_cmd] = policy.github.repos
    assert plain.name == "nyelbangash/sandbox"
    assert plain.test_command == nil
    assert plain.playwright_command == nil
    assert with_cmd.name == "nyelbangash/other"
    assert with_cmd.test_command == "mix test"
    assert with_cmd.playwright_command == "npx playwright test"
  end

  test "rejects malformed repo entries" do
    raw = put_in(base_raw(), ["github", "repos"], ["not-a-repo"])
    assert {:error, [error]} = Schema.parse(raw)
    assert error =~ "github.repos"
  end

  test "parses projects with an assignee trigger (default and explicit)" do
    raw =
      put_in(base_raw(), ["github", "projects"], [
        %{"owner" => "someorg", "number" => 7},
        %{"owner" => "someuser", "number" => 8, "trigger" => "assignee"}
      ])

    assert {:ok, policy} = Schema.parse(raw)
    assert [default, explicit] = policy.github.projects
    assert default.owner == "someorg"
    assert default.number == 7
    assert default.trigger == :assignee
    assert explicit.trigger == :assignee
  end

  test "parses a project with a field trigger" do
    raw =
      put_in(base_raw(), ["github", "projects"], [
        %{
          "owner" => "someorg",
          "number" => 7,
          "trigger" => %{"field" => "Status", "value" => "Ready"}
        }
      ])

    assert {:ok, policy} = Schema.parse(raw)
    assert [project] = policy.github.projects
    assert project.trigger == {:field, "Status", "Ready"}
  end

  test "rejects malformed project entries" do
    for bad <- [
          %{"number" => 7},
          %{"owner" => "someorg"},
          %{"owner" => "someorg", "number" => "not-a-number"},
          %{"owner" => "someorg", "number" => 7, "trigger" => %{"field" => "Status"}},
          %{"owner" => "someorg", "number" => 7, "trigger" => "nope"}
        ] do
      raw = put_in(base_raw(), ["github", "projects"], [bad])
      assert {:error, [error]} = Schema.parse(raw)
      assert error =~ "github.projects"
    end
  end

  test "unknown keys are ignored so the yaml can grow ahead of the code" do
    assert {:ok, _} = Schema.parse(Map.put(base_raw(), "future_section", %{"x" => 1}))
  end
end
