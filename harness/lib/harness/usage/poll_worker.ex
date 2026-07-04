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
          Harness.Usage.record_oauth_sample!(attrs)
          :ok

        {:error, reason} ->
          Logger.warning("usage poll failed (fail-closed on staleness): #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp due?(policy) do
    horizon =
      DateTime.add(DateTime.utc_now(), -policy.utilization_gates.poll_minutes, :minute)

    not Harness.Repo.exists?(
      from(s in Sample, where: s.source == "oauth_api" and s.sampled_at > ^horizon)
    )
  end
end
