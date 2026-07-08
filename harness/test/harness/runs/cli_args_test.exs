defmodule Harness.Runs.CLIArgsTest do
  use ExUnit.Case, async: true

  alias Harness.Runs.{CLIArgs, RunSpec}

  defp spec(overrides) do
    struct!(
      %RunSpec{
        kind: :plan,
        model: "sonnet",
        prompt: "do the thing",
        cwd: "/tmp/wt",
        allowed_tools: ["Read", "Glob", "Bash(git log *)"]
      },
      overrides
    )
  end

  test "stream-json argv (snapshot): verbose required, all isolation flags present" do
    assert CLIArgs.build(spec(output_mode: :stream_json)) == [
             "-p",
             "do the thing",
             "--output-format",
             "stream-json",
             "--verbose",
             "--model",
             "sonnet",
             "--permission-mode",
             "dontAsk",
             "--allowedTools",
             "Read,Glob,Bash(git log *)",
             "--setting-sources",
             "",
             "--strict-mcp-config",
             "--no-session-persistence"
           ]
  end

  test "json mode with schema (triage shape)" do
    argv =
      CLIArgs.build(spec(output_mode: :json, json_schema: ~s({"type":"object"})))

    assert ["-p", _, "--output-format", "json", "--json-schema", ~s({"type":"object"}) | _] = argv
    refute "--verbose" in argv
  end

  test "the forbidden flags never appear" do
    argv = CLIArgs.build(spec([]))

    for forbidden <- ["--bare", "--dangerously-skip-permissions", "bypassPermissions"] do
      refute forbidden in argv, "#{forbidden} must never reach a headless run"
    end
  end

  test "no subagents: no --agents flag" do
    argv = CLIArgs.build(spec([]))
    refute "--agents" in argv
  end

  test "subagents present: emits --agents as name -> {description, prompt, model}" do
    argv =
      CLIArgs.build(
        spec(
          subagents: [
            %{name: "reader", description: "reads things", prompt: "be a reader", model: "haiku"}
          ]
        )
      )

    assert ["--agents", json] = Enum.drop_while(argv, &(&1 != "--agents"))

    assert Jason.decode!(json) == %{
             "reader" => %{
               "description" => "reads things",
               "prompt" => "be a reader",
               "model" => "haiku"
             }
           }
  end

  test "env scrubs every Anthropic billing variable" do
    env = CLIArgs.env()

    for var <- [~c"ANTHROPIC_API_KEY", ~c"ANTHROPIC_AUTH_TOKEN", ~c"ANTHROPIC_BASE_URL"] do
      assert {var, false} in env
    end
  end
end
