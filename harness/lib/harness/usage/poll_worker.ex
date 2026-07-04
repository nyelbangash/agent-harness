defmodule Harness.Usage.PollWorker do
  @moduledoc """
  Polls the usage strategy every `utilization_gates.poll_minutes`. Cron fires
  every minute (Oban cron is boot-fixed; poll_minutes hot-reloads), and the
  worker exits early when a poll isn't due. Endpoint failures only log —
  staleness itself is the fail-closed signal (`Usage.current_mode/0`).
  """

  use Oban.Worker, queue: :ops, max_attempts: 1, unique: [period: 55]

  require Logger

  import Ecto.Query

  alias Harness.Usage.Sample

  @impl Oban.Worker
  def perform(_job) do
    policy = Harness.Policy.get()

    if due?(policy) do
      strategy = Harness.Usage.Strategy.for_billing_model(policy.billing_model)

      case strategy.fetch_usage() do
        {:ok, attrs} ->
          # a 200 whose shape drifted (all utilizations nil) must count as a
          # FAILURE — recording it would mark telemetry "fresh" while
          # mode_for's nil fallback silently paused every lane
          if utilization_readable?(attrs) do
            Harness.Usage.record_oauth_sample!(attrs)
          else
            Logger.warning("usage endpoint answered 200 but shape unreadable; not recording")
          end

          :ok

        {:error, reason} ->
          Logger.warning("usage poll failed (fail-closed on staleness): #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp utilization_readable?(attrs) do
    Enum.any?(
      [
        attrs[:five_hour_utilization],
        attrs[:seven_day_utilization],
        attrs[:seven_day_opus_utilization]
      ],
      &is_number/1
    )
  end

  defp due?(policy) do
    horizon =
      DateTime.add(DateTime.utc_now(), -policy.utilization_gates.poll_minutes, :minute)

    not Harness.Repo.exists?(
      from(s in Sample, where: s.source == "oauth_api" and s.sampled_at > ^horizon)
    )
  end
end
