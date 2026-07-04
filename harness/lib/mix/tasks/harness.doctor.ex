defmodule Mix.Tasks.Harness.Doctor do
  @shortdoc "Check the harness environment (Phase 0 gate)"

  @moduledoc """
  Runs every environment check and prints a report. Exits non-zero if any
  check fails. This is the Phase 0 acceptance gate.

      mix harness.doctor
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    results = Harness.Doctor.run_all()

    Mix.shell().info("")

    for {check, result} <- results do
      {glyph, detail} =
        case result do
          {:ok, info} -> {"✓", info}
          {:warn, message} -> {"!", message}
          {:error, message} -> {"✗", message}
        end

      Mix.shell().info("  #{glyph}  #{String.pad_trailing(check.label, 42)} #{detail}")
    end

    Mix.shell().info("")

    errors = for {_check, {:error, _}} <- results, do: :error

    if errors == [] do
      Mix.shell().info("All checks passed.")
    else
      Mix.raise("#{length(errors)} check(s) failed.")
    end
  end
end
