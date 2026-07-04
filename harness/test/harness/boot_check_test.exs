defmodule Harness.BootCheckTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Harness.BootCheck
  alias Harness.Doctor.Check

  defp check(id, boot), do: %Check{id: id, label: to_string(id), boot: boot, run: fn -> :unused end}

  test "the anthropic env check errors when the billing-trap variables are set" do
    env_check = Enum.find(Harness.Doctor.checks(), &(&1.id == :anthropic_env))
    assert env_check.boot == :critical

    System.put_env("ANTHROPIC_API_KEY", "sk-test-boot-check")
    on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)

    assert {:error, message} = env_check.run.()
    assert message =~ "ANTHROPIC_API_KEY"
    assert message =~ "Max subscription"
  end

  test "the anthropic env check passes when unset" do
    env_check = Enum.find(Harness.Doctor.checks(), &(&1.id == :anthropic_env))
    refute System.get_env("ANTHROPIC_API_KEY")
    assert {:ok, _} = env_check.run.()
  end

  test "a critical failure refuses boot even at :warn level" do
    results = [{check(:anthropic_env, :critical), {:error, "key present"}}]

    assert_raise RuntimeError, ~r/refused to boot.*key present/s, fn ->
      BootCheck.enforce!(results, :warn)
    end
  end

  test "a required failure refuses boot at :strict but only warns at :warn" do
    results = [{check(:claude_auth, :required), {:error, "not logged in"}}]

    assert_raise RuntimeError, ~r/not logged in/, fn ->
      BootCheck.enforce!(results, :strict)
    end

    log = capture_log(fn -> assert :ok = BootCheck.enforce!(results, :warn) end)
    assert log =~ "not logged in"
  end

  test "warn results never refuse boot" do
    results = [{check(:github_pat, :none), {:warn, "no PAT yet"}}]

    log = capture_log(fn -> assert :ok = BootCheck.enforce!(results, :strict) end)
    assert log =~ "no PAT yet"
  end

  test "ok results boot silently" do
    results = [{check(:claude_version, :required), {:ok, "2.1.195"}}]
    assert :ok = BootCheck.enforce!(results, :strict)
  end
end
