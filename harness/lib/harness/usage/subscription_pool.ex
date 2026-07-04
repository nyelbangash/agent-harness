defmodule Harness.Usage.SubscriptionPool do
  @moduledoc """
  Reads Max-plan utilization from `https://claude.ai/api/oauth/usage` using
  Claude Code's own OAuth access token (Keychain, never cached — the CLI
  refreshes it underneath us).

  This endpoint is UNDOCUMENTED. Known constraints (community-verified,
  July 2026): requires a `claude-code/<version>` User-Agent (anything else
  gets aggressively rate-limited), returns `{five_hour, seven_day,
  seven_day_opus}` objects with `utilization` (0–100) and `resets_at`;
  `seven_day.resets_at` does not predict actual resets. Callers must treat
  every failure as expected — staleness fails closed to plan_only upstream.
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

  @doc "Shape the endpoint body into `usage_samples` attrs."
  def parse(body) do
    %{
      five_hour_utilization: utilization(body["five_hour"]),
      five_hour_resets_at: resets_at(body["five_hour"]),
      seven_day_utilization: utilization(body["seven_day"]),
      seven_day_resets_at: resets_at(body["seven_day"]),
      seven_day_opus_utilization: utilization(body["seven_day_opus"]),
      raw: body
    }
  end

  defp utilization(%{"utilization" => value}) when is_number(value), do: value / 1
  defp utilization(_), do: nil

  defp resets_at(%{"resets_at" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp resets_at(_), do: nil

  defp url do
    Application.get_env(:harness, :usage_endpoint, "https://claude.ai/api/oauth/usage")
  end
end
