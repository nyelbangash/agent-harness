defmodule Harness.Secrets do
  @moduledoc """
  Reads credentials from the macOS login Keychain via `security(1)`.
  Requires a GUI login session — this is why the daemon runs as a
  LaunchAgent (gui domain), never a LaunchDaemon.

  Nothing here is ever written to the repo, the plist, or logs.
  """

  @pat_service "com.nyel.harness.github"
  @claude_service "Claude Code-credentials"

  @doc "Keychain service name for the GitHub PAT (used by `mix harness.setup`)."
  def pat_service, do: @pat_service

  @doc """
  The fine-grained GitHub PAT. Cached in `:persistent_term` after the first
  read — the token is long-lived and Keychain reads can prompt.
  """
  @spec github_pat() :: {:ok, String.t()} | {:error, :not_found}
  def github_pat do
    cond do
      override = Application.get_env(:harness, :github_pat) ->
        {:ok, override}

      pat = :persistent_term.get({__MODULE__, :github_pat}, nil) ->
        {:ok, pat}

      true ->
        with {:ok, pat} <- read_password(service: @pat_service, account: System.get_env("USER")) do
          :persistent_term.put({__MODULE__, :github_pat}, pat)
          {:ok, pat}
        end
    end
  end

  @doc "Drop the cached PAT (after rotation via `mix harness.setup`)."
  def forget_github_pat, do: :persistent_term.erase({__MODULE__, :github_pat})

  @doc """
  Claude Code's own OAuth credentials (for the usage poller). Never cached —
  the CLI refreshes the access token underneath us.
  """
  @spec claude_oauth() ::
          {:ok, %{access_token: String.t(), refresh_token: String.t() | nil, expires_at: integer() | nil}}
          | {:error, :not_found | :unexpected_shape}
  def claude_oauth do
    if token = Application.get_env(:harness, :claude_oauth_token) do
      {:ok, %{access_token: token, refresh_token: nil, expires_at: nil}}
    else
      read_claude_oauth()
    end
  end

  defp read_claude_oauth do
    with {:ok, json} <- read_password(service: @claude_service),
         {:ok, %{"claudeAiOauth" => oauth}} <- Jason.decode(json),
         %{"accessToken" => access} <- oauth do
      {:ok,
       %{
         access_token: access,
         refresh_token: oauth["refreshToken"],
         expires_at: oauth["expiresAt"]
       }}
    else
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :unexpected_shape}
    end
  end

  defp read_password(opts) do
    args =
      ["find-generic-password", "-s", Keyword.fetch!(opts, :service)] ++
        case Keyword.get(opts, :account) do
          nil -> []
          account -> ["-a", account]
        end ++ ["-w"]

    case System.cmd("security", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim_trailing(output, "\n")}
      {_output, _} -> {:error, :not_found}
    end
  end
end
