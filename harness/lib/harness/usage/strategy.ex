defmodule Harness.Usage.Strategy do
  @moduledoc """
  Billing-model seam (spec §11). `SubscriptionPool` is today's reality
  (Max subscription, seven-day utilization gates). When Anthropic ships the
  SDK-credit split, implement `SdkCredit` and flip `billing_model` in
  policy.yaml — gate math then tracks credit balance instead.
  """

  @doc "Fetch a utilization snapshot, as `usage_samples` attrs (0–100 scale)."
  @callback fetch_usage() :: {:ok, map()} | {:error, term()}

  @spec for_billing_model(atom()) :: module()
  def for_billing_model(:subscription_pool), do: Harness.Usage.SubscriptionPool
  def for_billing_model(:sdk_credit), do: Harness.Usage.SdkCredit
end
