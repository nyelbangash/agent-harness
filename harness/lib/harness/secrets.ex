defmodule Harness.Secrets do
  @moduledoc """
  Reads credentials from the macOS login Keychain via `security(1)`.
  Requires a GUI login session — this is why the daemon runs as a
  LaunchAgent (gui domain), never a LaunchDaemon.

  Nothing here is ever written to the repo, the plist, or logs.
  """

  @pat_service "com.nyel.harness.github"
  @claude_service "Claude Code-credentials"

  @doc "Keychain service name for the default GitHub PAT (used by `mix harness.setup`)."
  def pat_service, do: @pat_service

  @doc "Keychain service name for `owner`'s GitHub PAT (used by `mix harness.setup <owner>`)."
  def pat_service(owner), do: "#{@pat_service}.#{owner}"

  @doc "The resource owner (user or org) a \"owner/name\" repo belongs to."
  def owner_of(repo), do: repo |> String.split("/", parts: 2) |> List.first()

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
        with {:ok, pat} <- read_password(@pat_service, System.get_env("USER")) do
          :persistent_term.put({__MODULE__, :github_pat}, pat)
          {:ok, pat}
        end
    end
  end

  @doc """
  The GitHub PAT for `repo` (an \"owner/name\" string): resolves the
  owner-suffixed Keychain service first, falling back to the default
  service. See `github_pat_for_owner/1` for the full resolution order.
  """
  @spec github_pat(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def github_pat(repo), do: repo |> owner_of() |> github_pat_for_owner()

  @doc """
  The GitHub PAT for `owner`. Resolution order:

    1. `:harness, :github_pat_overrides` test seam (per-owner)
    2. `:harness, :github_pat` global override (existing test/config seam)
    3. `:persistent_term` cache
    4. Keychain service `com.nyel.harness.github.<owner>`, falling back to
       the default service `com.nyel.harness.github` if not found
  """
  @spec github_pat_for_owner(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def github_pat_for_owner(owner) do
    cond do
      override = Application.get_env(:harness, :github_pat_overrides, %{})[owner] ->
        {:ok, override}

      override = Application.get_env(:harness, :github_pat) ->
        {:ok, override}

      pat = :persistent_term.get({__MODULE__, :github_pat, owner}, nil) ->
        {:ok, pat}

      true ->
        resolve_and_cache_owner_pat(owner)
    end
  end

  defp resolve_and_cache_owner_pat(owner) do
    result =
      case read_password(pat_service(owner), System.get_env("USER")) do
        {:ok, pat} -> {:ok, pat}
        {:error, :not_found} -> read_password(@pat_service, System.get_env("USER"))
      end

    with {:ok, pat} <- result do
      :persistent_term.put({__MODULE__, :github_pat, owner}, pat)
      {:ok, pat}
    end
  end

  @doc "Drop the cached default PAT (after rotation via `mix harness.setup`)."
  def forget_github_pat, do: :persistent_term.erase({__MODULE__, :github_pat})

  @doc "Drop the cached PAT for `owner` (after rotation via `mix harness.setup <owner>`)."
  def forget_github_pat(owner), do: :persistent_term.erase({__MODULE__, :github_pat, owner})

  @doc """
  Claude Code's own OAuth credentials (for the usage poller). Never cached —
  the CLI refreshes the access token underneath us.
  """
  @spec claude_oauth() ::
          {:ok,
           %{
             access_token: String.t(),
             refresh_token: String.t() | nil,
             expires_at: integer() | nil
           }}
          | {:error, :not_found | :unexpected_shape}
  def claude_oauth do
    if token = Application.get_env(:harness, :claude_oauth_token) do
      {:ok, %{access_token: token, refresh_token: nil, expires_at: nil}}
    else
      read_claude_oauth()
    end
  end

  defp read_claude_oauth do
    with {:ok, json} <- read_password(@claude_service, nil),
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

  defp read_password(service, account) do
    backend().find_generic_password(service, account)
  end

  defp backend do
    Application.get_env(:harness, :keychain_backend, Harness.Secrets.Keychain.System)
  end
end
