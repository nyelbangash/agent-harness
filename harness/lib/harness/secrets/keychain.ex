defmodule Harness.Secrets.Keychain do
  @moduledoc """
  Swappable Keychain access, so tests can simulate multiple Keychain
  services without a real Keychain (mirrors the `:runner`/`:notify_backend`
  swap-module pattern).
  """

  @callback find_generic_password(service :: String.t(), account :: String.t() | nil) ::
              {:ok, String.t()} | {:error, :not_found}
end
