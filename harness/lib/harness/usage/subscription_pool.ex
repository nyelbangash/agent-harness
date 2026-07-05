defmodule Harness.Usage.SubscriptionPool do
  @moduledoc """
  Reads Max-plan utilization from `https://claude.ai/api/oauth/usage` using
  Claude Code's own OAuth access token (Keychain, never cached — the CLI
  refreshes it underneath us).

  This endpoint is UNDOCUMENTED and has changed at least once (2026-07-05).
  Two known shapes are handled; `parse/1` tries the new shape first and falls
  back to legacy when `rate_limit_info` is absent:

  Legacy (pre-2026-07-05):
    `{"five_hour": {"utilization": 0-100, "resets_at": "<iso8601>"}, ...}`

  New (from 2026-07-05):
    `{"rate_limit_info": {"isUsingOverage": bool, "overageStatus": "...",
       "rateLimitType": "five_hour", "resetsAt": <unix-seconds>, ...}}`
    Numeric utilization is absent; inferred from overage flags.

  Callers must treat every failure as expected — staleness fails closed to
  plan_only upstream.
  """

  @behaviour Harness.Usage.Strategy

  @user_agent "claude-code/2.1.195"

  @impl true
  def fetch_usage do
    with {:ok, %{access_token: token}} <- Harness.Secrets.claude_oauth(),
         {:ok, %{status: 200, body: %{} = body}} <-
           Req.request(
             [
               method: :get,
               url: url(),
               headers: [{"authorization", "Bearer #{token}"}, {"user-agent", @user_agent}],
               retry: false,
               receive_timeout: 15_000
             ] ++ Application.get_env(:harness, :usage_req_options, [])
           ) do
      {:ok, parse(body)}
    else
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Shape the endpoint body into `usage_samples` attrs. Handles both the new rate_limit_info and legacy shapes."
  def parse(%{"rate_limit_info" => info} = body) when is_map(info) do
    parse_new_shape(body, info)
  end

  def parse(body) do
    parse_legacy_shape(body)
  end

  defp parse_new_shape(body, info) do
    %{
      five_hour_utilization: infer_utilization(info),
      five_hour_resets_at: resets_at_unix(info["resetsAt"]),
      seven_day_utilization: nil,
      seven_day_resets_at: nil,
      seven_day_opus_utilization: nil,
      raw: body
    }
  end

  defp parse_legacy_shape(body) do
    %{
      five_hour_utilization: utilization(body["five_hour"]),
      five_hour_resets_at: resets_at(body["five_hour"]),
      seven_day_utilization: utilization(body["seven_day"]),
      seven_day_resets_at: resets_at(body["seven_day"]),
      seven_day_opus_utilization: utilization(body["seven_day_opus"]),
      raw: body
    }
  end

  # Infer utilization from the new shape's boolean overage flags.
  # Conservative: any overage maps to a high utilization band; no overage returns nil (unreadable).
  defp infer_utilization(%{"overageStatus" => "paused"}), do: 100.0
  defp infer_utilization(%{"isUsingOverage" => true, "overageStatus" => "allowed"}), do: 90.0
  defp infer_utilization(%{"isUsingOverage" => true}), do: 95.0
  defp infer_utilization(_), do: nil

  defp utilization(%{"utilization" => value}) when is_number(value), do: value / 1
  defp utilization(_), do: nil

  defp resets_at(%{"resets_at" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp resets_at(_), do: nil

  defp resets_at_unix(nil), do: nil

  defp resets_at_unix(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp resets_at_unix(_), do: nil

  defp url do
    Application.get_env(:harness, :usage_endpoint, "https://claude.ai/api/oauth/usage")
  end
end
