defmodule Harness.BootCheck do
  @moduledoc """
  Pre-supervision boot assertions. Level comes from `:boot_check_level`:

    * `:strict` (prod) — any failed boot check refuses to start
    * `:warn` (dev) — failures log warnings, except the `:critical`
      billing-trap check (ANTHROPIC_API_KEY), which always refuses
    * `:skip` (test) — no checks

  Network checks (GitHub API) are deliberately NOT boot checks — a flaky
  network must not crash-loop the daemon under launchd KeepAlive. They live
  in `mix harness.doctor`.
  """

  require Logger

  @spec assert!() :: :ok
  def assert! do
    case Application.get_env(:harness, :boot_check_level, :strict) do
      :skip -> :ok
      level when level in [:warn, :strict] -> enforce!(Harness.Doctor.run_boot(level), level)
    end
  end

  @doc "Raise unless the given `[{check, result}]` pass at `level`."
  @spec enforce!([{Harness.Doctor.Check.t(), term()}], :warn | :strict) :: :ok
  def enforce!(results, level) do
    failures =
      for {check, result} <- results,
          message = failure_message(check, result, level),
          do: message

    case failures do
      [] ->
        :ok

      messages ->
        raise """
        Harness refused to boot — failed environment checks:

        #{Enum.map_join(messages, "\n", &("  ✗ " <> &1))}

        Run `mix harness.doctor` for the full report.
        """
    end
  end

  # critical checks fail the boot at every level; required ones only at :strict
  defp failure_message(check, {:error, message}, level) do
    cond do
      check.boot == :critical -> "#{check.label}: #{message}"
      level == :strict -> "#{check.label}: #{message}"
      true -> warn(check, message)
    end
  end

  defp failure_message(check, {:warn, message}, _level), do: warn(check, message)
  defp failure_message(_check, {:ok, _}, _level), do: nil

  defp warn(check, message) do
    Logger.warning("boot check #{check.id}: #{message}")
    nil
  end
end
