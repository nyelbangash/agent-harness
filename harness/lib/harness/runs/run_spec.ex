defmodule Harness.Runs.RunSpec do
  @moduledoc """
  Semantic description of one headless run. `Harness.Runs.CLIArgs` turns this
  into argv; the runner owns the process. Keep policy knobs (model, turn caps,
  tool whitelist) here so workers never touch CLI syntax.
  """

  @enforce_keys [:kind, :model, :prompt, :cwd, :allowed_tools, :max_turns]
  defstruct [
    :kind,
    :model,
    :prompt,
    :cwd,
    :allowed_tools,
    :max_turns,
    :json_schema,
    :issue_id,
    :ref,
    :worktree,
    output_mode: :stream_json,
    permission_mode: "dontAsk",
    timeout_ms: :timer.minutes(30)
  ]

  @type t :: %__MODULE__{
          kind: :triage | :implement | :plan | :ideate | :critique | :promote,
          model: String.t(),
          prompt: String.t(),
          cwd: Path.t(),
          allowed_tools: [String.t()],
          max_turns: pos_integer(),
          json_schema: String.t() | nil,
          issue_id: integer() | nil,
          ref: String.t() | nil,
          worktree: Path.t() | nil,
          output_mode: :json | :stream_json,
          permission_mode: String.t(),
          timeout_ms: pos_integer()
        }
end
