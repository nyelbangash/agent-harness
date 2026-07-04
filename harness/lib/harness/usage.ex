defmodule Harness.Usage do
  @moduledoc """
  Usage/utilization context. Phase 1.8 wires this to `usage_samples`
  (claude.ai OAuth usage endpoint + rate_limit_events from real runs) with
  fail-closed staleness handling. Until then the gates see `:full_auto`.
  """

  @type mode :: :full_auto | :defer_ideation | :plan_only | :pause

  @spec current_mode() :: mode()
  def current_mode, do: :full_auto

  @spec health() :: :ok | :stale
  def health, do: :ok
end
