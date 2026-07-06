defmodule Harness.SecretsTest do
  # async: false — swaps global :keychain_backend / :fake_keychain_passwords /
  # :github_pat and mutates the shared :persistent_term PAT cache
  use ExUnit.Case, async: false

  alias Harness.Secrets

  setup do
    # config/test.exs sets a global :github_pat override so every other test
    # can assume "test-pat" without touching Secrets — that override would
    # otherwise mask every Keychain-fallback assertion here.
    global_override = Application.get_env(:harness, :github_pat)
    Application.delete_env(:harness, :github_pat)
    Application.put_env(:harness, :keychain_backend, Harness.Secrets.FakeKeychain)

    on_exit(fn ->
      Application.delete_env(:harness, :keychain_backend)
      Application.delete_env(:harness, :fake_keychain_passwords)

      if global_override, do: Application.put_env(:harness, :github_pat, global_override)
    end)

    :ok
  end

  # persistent_term caches survive across tests, so each test gets its own
  # owner name — otherwise a later test could observe an earlier test's
  # cached PAT instead of exercising the Keychain fallback it's testing.
  defp unique_owner(tag), do: "#{tag}-#{System.unique_integer([:positive])}"

  defp seed(passwords), do: Application.put_env(:harness, :fake_keychain_passwords, passwords)

  test "github_pat_for_owner prefers the owner-suffixed service over the default" do
    owner = unique_owner("acme")

    seed(%{
      Secrets.pat_service(owner) => "acme-pat",
      Secrets.pat_service() => "default-pat"
    })

    assert {:ok, "acme-pat"} = Secrets.github_pat_for_owner(owner)
  end

  test "github_pat_for_owner falls back to the default service when unset" do
    owner = unique_owner("acme")
    seed(%{Secrets.pat_service() => "default-pat"})

    assert {:ok, "default-pat"} = Secrets.github_pat_for_owner(owner)
  end

  test "github_pat_for_owner returns :not_found when neither service is seeded" do
    owner = unique_owner("acme")
    seed(%{})

    assert {:error, :not_found} = Secrets.github_pat_for_owner(owner)
  end

  test "github_pat/1 derives the owner from \"owner/name\" and resolves its PAT" do
    owner = unique_owner("acme")
    seed(%{Secrets.pat_service(owner) => "acme-pat"})

    assert {:ok, "acme-pat"} = Secrets.github_pat("#{owner}/repo")
  end

  test "two owners resolve independently and don't share a persistent_term cache slot" do
    acme = unique_owner("acme")
    globex = unique_owner("globex")

    seed(%{
      Secrets.pat_service(acme) => "acme-pat",
      Secrets.pat_service(globex) => "globex-pat"
    })

    assert {:ok, "acme-pat"} = Secrets.github_pat_for_owner(acme)
    assert {:ok, "globex-pat"} = Secrets.github_pat_for_owner(globex)

    # forget_github_pat/1 only clears the named owner's cache slot
    Secrets.forget_github_pat(acme)
    seed(%{Secrets.pat_service(globex) => "globex-pat"})

    assert {:error, :not_found} = Secrets.github_pat_for_owner(acme)
    assert {:ok, "globex-pat"} = Secrets.github_pat_for_owner(globex)
  end
end
