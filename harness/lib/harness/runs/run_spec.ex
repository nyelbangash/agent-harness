defmodule Harness.Runs.RunSpec do
  @moduledoc """
  Semantic description of one headless run. `Harness.Runs.CLIArgs` turns this
  into argv; the runner owns the process. Keep policy knobs (model, tool
  whitelist) here so workers never touch CLI syntax. Runs are bounded by
  wall-clock (`timeout_ms`), not by a turn cap.
  """

  @enforce_keys [:kind, :model, :prompt, :cwd, :allowed_tools]
  defstruct [
    :kind,
    :model,
    :prompt,
    :cwd,
    :allowed_tools,
    :json_schema,
    :issue_id,
    :ref,
    :worktree,
    output_mode: :stream_json,
    permission_mode: "dontAsk",
    timeout_ms: :timer.minutes(30),
    subagents: []
  ]

  @type subagent :: %{
          name: String.t(),
          description: String.t(),
          prompt: String.t(),
          model: String.t()
        }

  @type t :: %__MODULE__{
          kind:
            :triage | :implement | :plan | :ideate | :critique | :review | :promote | :explore,
          model: String.t(),
          prompt: String.t(),
          cwd: Path.t(),
          allowed_tools: [String.t()],
          json_schema: String.t() | nil,
          issue_id: integer() | nil,
          ref: String.t() | nil,
          worktree: Path.t() | nil,
          output_mode: :json | :stream_json,
          permission_mode: String.t(),
          timeout_ms: pos_integer(),
          subagents: [subagent()]
        }
end
