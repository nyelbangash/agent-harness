defmodule Harness.Runs.Runner do
  @moduledoc """
  Behaviour for run execution. `Runner.ClaudeCLI` shells out to headless
  claude; tests configure `Harness.Runs.FakeRunner`. Workers stay agnostic —
  they call `Harness.Runs.execute/1` and receive a `%Result{}`.
  """

  defmodule Result do
    @moduledoc "Distilled outcome of a run (mirrors the CLI result envelope)."

    @enforce_keys [:run_id, :subtype]
    defstruct [
      :run_id,
      :subtype,
      :structured_output,
      :result_text,
      :session_id,
      turns: 0,
      tokens_in: 0,
      tokens_out: 0,
      cost: 0.0,
      permission_denials: []
    ]

    @type t :: %__MODULE__{}
  end

  @callback execute(Harness.Runs.RunSpec.t(), keyword()) ::
              {:ok, Result.t()}
              | {:error, :killed | :timeout | {:cli_exit, integer()} | term()}
end
