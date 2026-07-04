defmodule Harness.Integration.ClaudeCLITest do
  @moduledoc """
  Hits the REAL claude CLI (subscription tokens!). Excluded by default; run
  deliberately as a Phase 1 gate rehearsal:

      mix test --only real_cli
  """

  use Harness.DataCase, async: false

  alias Harness.GitHub.Triage
  alias Harness.Runs.{Runner, RunSpec}

  @moduletag :real_cli
  @moduletag timeout: :timer.minutes(6)

  setup do
    tmp = Path.join(System.tmp_dir!(), "real-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    File.write!(Path.join(tmp, "README.md"), """
    # fixture-app

    A tiny fixture project. It has a typoo on this line.
    """)

    File.write!(Path.join(tmp, "widget.ex"), "defmodule Widget do\nend\n")

    {output, 0} = System.cmd("git", ["init", "-q"], cd: tmp, stderr_to_stdout: true)
    _ = output
    System.cmd("git", ["add", "-A"], cd: tmp)

    System.cmd(
      "git",
      ~w(-c user.name=fixture -c user.email=f@t commit -q -m seed),
      cd: tmp
    )

    on_exit(fn -> File.rm_rf!(tmp) end)
    %{repo_dir: tmp}
  end

  test "a real triage run returns schema-valid structured output end to end", %{repo_dir: dir} do
    issue_prompt = """
    You are the triage stage of an automated development pipeline. Assess this issue
    against the repository you are in (read-only) and answer with only the JSON object
    matching the provided schema.

    <<<ISSUE-DATA repo=fixture/app issue=#1>>>
    Title: Fix typo in README
    Body: The README says "typoo" — should be "typo".
    <<<END-ISSUE-DATA>>>
    """

    spec = %RunSpec{
      kind: :triage,
      model: "sonnet",
      prompt: issue_prompt,
      cwd: dir,
      output_mode: :json,
      json_schema: Triage.schema_json(),
      allowed_tools: ["Read", "Glob", "Grep", "Bash(ls *)"],
      max_turns: 8,
      ref: "fixture/app#1",
      timeout_ms: :timer.minutes(5)
    }

    assert {:ok, %Runner.Result{} = result} = Runner.ClaudeCLI.execute(spec, [])

    # the CLI-validated structured output re-validates in Elixir
    assert result.subtype == "success"
    assert {:ok, decision} = Triage.validate(result.structured_output)
    assert decision.route in ~w(auto plan skip)
    assert decision.estimated_scope in ~w(xs s m l)

    # the run ledger captured the session
    run = Harness.Runs.get_run!(result.run_id)
    assert run.status == "succeeded"
    assert run.session_id
    assert run.cost_estimate > 0
    assert length(Harness.Runs.events(run.id)) >= 1
  end
end
