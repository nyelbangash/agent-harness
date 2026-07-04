defmodule Harness.GitHub.TriageTest do
  use ExUnit.Case, async: true

  import Harness.Fixtures, only: [triage_output: 1, triage_output: 0]

  alias Harness.GitHub.Triage

  describe "schema_json/0" do
    test "matches the §4.2 contract exactly" do
      schema = Jason.decode!(Triage.schema_json())

      assert schema["required"] == ~w(route confidence reasoning estimated_scope risk_flags)
      assert schema["additionalProperties"] == false
      assert schema["properties"]["route"]["enum"] == ~w(auto plan skip)
      assert schema["properties"]["estimated_scope"]["enum"] == ~w(xs s m l)
      assert schema["properties"]["confidence"]["minimum"] == 0
      assert schema["properties"]["confidence"]["maximum"] == 1
    end
  end

  describe "validate/1" do
    test "accepts a valid payload" do
      assert {:ok, decision} = Triage.validate(triage_output())
      assert decision.route == "plan"
      assert decision.confidence == 0.8
    end

    test "accepts integer confidence (JSON 1 vs 1.0)" do
      assert {:ok, decision} = Triage.validate(triage_output(confidence: 1))
      assert decision.confidence === 1.0
    end

    for {field, value, hint} <- [
          {"route", "maybe", "route"},
          {"confidence", 1.2, "confidence"},
          {"confidence", -0.1, "confidence"},
          {"confidence", "high", "confidence"},
          {"estimated_scope", "xl", "estimated_scope"},
          {"risk_flags", "none", "risk_flags"},
          {"risk_flags", [1, 2], "risk_flags"},
          {"reasoning", 42, "reasoning"}
        ] do
      test "rejects #{field} = #{inspect(value)}" do
        payload = triage_output(%{unquote(field) => unquote(Macro.escape(value))})
        assert {:error, errors} = Triage.validate(payload)
        assert Enum.any?(errors, &(&1 =~ unquote(hint)))
      end
    end

    test "rejects missing required keys" do
      assert {:error, errors} = Triage.validate(Map.delete(triage_output(), "route"))
      assert "route: missing" in errors
    end

    test "rejects unknown extra keys" do
      assert {:error, errors} = Triage.validate(Map.put(triage_output(), "notes", "hi"))
      assert "notes: unknown key" in errors
    end

    test "rejects non-map output" do
      assert {:error, _} = Triage.validate("just text")
      assert {:error, _} = Triage.validate(nil)
    end
  end

  describe "route/2 — the §4.2 table" do
    defp decision(attrs) do
      {:ok, decision} = Triage.validate(triage_output(attrs))
      decision
    end

    defp ctx(overrides \\ %{}) do
      Map.merge(
        %{labels: [], auto_threshold: 0.75, test_command?: true, full_auto_active?: true},
        overrides
      )
    end

    test "auto passes only when every gate is open" do
      d = decision(%{route: "auto", confidence: 0.8, estimated_scope: "xs"})
      assert {"auto", "all_gates_passed"} = Triage.route(d, ctx())
    end

    test "auto demotes outside full-auto (mode/window/usage)" do
      d = decision(%{route: "auto", confidence: 0.8, estimated_scope: "xs"})
      assert {"plan", "mode_not_full_auto"} = Triage.route(d, ctx(%{full_auto_active?: false}))
    end

    test "auto demotes below the confidence threshold" do
      d = decision(%{route: "auto", confidence: 0.74, estimated_scope: "xs"})
      assert {"plan", "confidence_below_threshold"} = Triage.route(d, ctx())
    end

    test "auto demotes on scope m and l" do
      for scope <- ["m", "l"] do
        d = decision(%{route: "auto", confidence: 0.9, estimated_scope: scope})
        assert {"plan", "scope_too_large"} = Triage.route(d, ctx())
      end
    end

    test "auto demotes on any risk flag" do
      d =
        decision(%{
          route: "auto",
          confidence: 0.9,
          estimated_scope: "s",
          risk_flags: ["touches_ci"]
        })

      assert {"plan", "risk_flags_present"} = Triage.route(d, ctx())
    end

    test "auto demotes without a configured test command" do
      d = decision(%{route: "auto", confidence: 0.9, estimated_scope: "s"})
      assert {"plan", "no_test_command"} = Triage.route(d, ctx(%{test_command?: false}))
    end

    test "human-only label skips regardless of proposal" do
      for route <- ["auto", "plan", "skip"] do
        d = decision(%{route: route, confidence: 0.9, estimated_scope: "xs"})
        assert {"skip", "human_only_label"} = Triage.route(d, ctx(%{labels: ["human-only"]}))
      end
    end

    test "model skip demotes to plan (spec-literal)" do
      d = decision(%{route: "skip", confidence: 0.95})
      assert {"plan", "model_skip_demoted"} = Triage.route(d, ctx())
    end

    test "proposed plan stays plan" do
      d = decision(%{route: "plan", confidence: 0.6})
      assert {"plan", "proposed_plan"} = Triage.route(d, ctx())
    end
  end
end
