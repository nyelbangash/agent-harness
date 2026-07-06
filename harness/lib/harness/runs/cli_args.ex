defmodule Harness.Runs.CLIArgs do
  @moduledoc """
  Pure `RunSpec → argv` builder. This is the security boundary with the
  agent process, so every isolation flag is unconditional:

    * `--setting-sources ""` — no user/project Claude settings leak in; a
      cloned target repo's `.claude/` cannot inject hooks or permissions
    * `--strict-mcp-config` — a repo-level `.mcp.json` cannot add MCP servers
    * `--no-session-persistence` — no session files litter `~/.claude`
    * `--permission-mode dontAsk` (default) — deny-by-default; only the
      explicit `--allowedTools` whitelist executes, denials surface in the
      result envelope
    * never `--bare` (it skips OAuth/Keychain → breaks subscription auth),
      never `--dangerously-skip-permissions`

  stream-json requires `--verbose` in print mode (verified on CLI 2.1.195).
  """

  alias Harness.Runs.RunSpec

  @spec build(RunSpec.t()) :: [String.t()]
  def build(%RunSpec{} = spec) do
    ["-p", spec.prompt] ++
      output_args(spec) ++
      [
        "--model",
        spec.model,
        "--permission-mode",
        spec.permission_mode,
        "--allowedTools",
        Enum.join(spec.allowed_tools, ","),
        "--setting-sources",
        "",
        "--strict-mcp-config",
        "--no-session-persistence"
      ]
  end

  defp output_args(%RunSpec{output_mode: :stream_json}) do
    ["--output-format", "stream-json", "--verbose"]
  end

  defp output_args(%RunSpec{output_mode: :json, json_schema: schema}) when is_binary(schema) do
    ["--output-format", "json", "--json-schema", schema]
  end

  defp output_args(%RunSpec{output_mode: :json}) do
    ["--output-format", "json"]
  end

  @doc """
  Environment for the Port, as `{charlist, value | false}` — `false` removes
  the variable from the child. ANTHROPIC_* removal is the billing guard: in
  print mode a present API key is silently preferred over the subscription.
  """
  @spec env() :: [{charlist(), charlist() | false}]
  def env do
    [
      {~c"ANTHROPIC_API_KEY", false},
      {~c"ANTHROPIC_AUTH_TOKEN", false},
      {~c"ANTHROPIC_BASE_URL", false},
      {~c"CLAUDE_CODE_OAUTH_TOKEN", false},
      # provider redirects would also bypass subscription billing
      {~c"CLAUDE_CODE_USE_BEDROCK", false},
      {~c"CLAUDE_CODE_USE_VERTEX", false},
      {~c"CLAUDE_CODE_USE_FOUNDRY", false}
    ]
  end
end
