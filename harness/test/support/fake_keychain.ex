defmodule Harness.Secrets.FakeKeychain do
  @moduledoc """
  Simulates Keychain services in memory, backed by
  `Application.get_env(:harness, :fake_keychain_passwords, %{})`
  (a `%{service_name => pat}` map), so tests can seed exactly which
  Keychain services "exist" without touching the real Keychain.
  """

  @behaviour Harness.Secrets.Keychain

  @impl true
  def find_generic_password(service, _account) do
    case Application.get_env(:harness, :fake_keychain_passwords, %{})[service] do
      nil -> {:error, :not_found}
      pat -> {:ok, pat}
    end
  end
end
