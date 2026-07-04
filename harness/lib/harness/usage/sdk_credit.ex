defmodule Harness.Usage.SdkCredit do
  @moduledoc """
  Placeholder for the announced-then-paused SDK-credit billing split
  (spec §11). When Anthropic ships it: fetch the monthly credit balance,
  map balance + overflow cap onto the gate modes, and flip
  `billing_model: sdk_credit` in policy.yaml.
  """

  @behaviour Harness.Usage.Strategy

  @impl true
  def fetch_usage, do: {:error, :not_implemented}
end
