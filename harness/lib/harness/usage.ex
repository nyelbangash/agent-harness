defmodule Harness.Usage do
  @moduledoc """
  Usage/utilization context (spec §7, §11).

  Two signals land in `usage_samples`:

    * `oauth_api` — polled from the undocumented claude.ai usage endpoint by
      `Usage.PollWorker` through the configured `Usage.Strategy`
    * `rate_limit_event` — emitted by every real run's stream (free telemetry)

  Gate math is fail-closed: with no fresh `oauth_api` sample within
  3 × poll_minutes, `current_mode/0` returns `:plan_only` and `health/0`
  returns `:stale` (Mission Control shows a warning banner).
  """

  import Ecto.Query

  alias Harness.Repo
  alias Harness.Usage.Sample

  @topic "usage"

  @type mode :: :full_auto | :defer_ideation | :plan_only | :pause

  def subscribe, do: Phoenix.PubSub.subscribe(Harness.PubSub, @topic)

  # -- gate inputs -----------------------------------------------------------------

  @spec current_mode() :: mode()
  def current_mode do
    policy = Harness.Policy.get()

    case fresh_oauth_sample(policy) do
      nil -> :plan_only
      sample -> mode_for(sample, policy)
    end
  end

  @spec health() :: :ok | :stale
  def health do
    if fresh_oauth_sample(Harness.Policy.get()), do: :ok, else: :stale
  end

  @doc "Derive the §7 gate mode from a sample's utilizations (0–100 scale)."
  @spec mode_for(Sample.t(), Harness.Policy.Schema.t()) :: mode()
  def mode_for(%Sample{} = sample, policy) do
    gates = policy.utilization_gates

    utilization =
      [sample.seven_day_utilization, sample.five_hour_utilization, sample.seven_day_opus_utilization]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> 100.0
        values -> Enum.max(values)
      end
      |> Kernel./(100.0)

    cond do
      utilization >= gates.pause_above -> :pause
      utilization >= gates.plan_only_above -> :plan_only
      utilization >= gates.defer_ideation_above -> :defer_ideation
      utilization < gates.full_auto_below -> :full_auto
      true -> :defer_ideation
    end
  end

  defp fresh_oauth_sample(policy) do
    horizon =
      DateTime.add(DateTime.utc_now(), -3 * policy.utilization_gates.poll_minutes, :minute)

    from(s in Sample,
      where: s.source == "oauth_api" and s.sampled_at > ^horizon,
      order_by: [desc: s.sampled_at],
      limit: 1
    )
    |> Repo.one()
  end

  # -- recording -----------------------------------------------------------------

  @doc "Record an oauth_api snapshot and broadcast; returns the sample."
  def record_oauth_sample!(attrs) do
    previous_mode = current_mode()

    sample =
      %Sample{}
      |> Sample.changeset(
        attrs
        |> Map.put(:source, "oauth_api")
        |> Map.put_new(:sampled_at, DateTime.utc_now())
      )
      |> Repo.insert!()

    broadcast({:usage_sample, sample})

    new_mode = current_mode()
    if new_mode != previous_mode, do: broadcast({:usage_mode_changed, new_mode})

    sample
  end

  @doc "Record the rate_limit_event a run emitted (second usage signal)."
  def ingest_rate_limit_event(_run, payload) do
    info = payload["rate_limit_info"] || %{}

    %Sample{}
    |> Sample.changeset(%{
      source: "rate_limit_event",
      rate_limit_status: info["status"],
      five_hour_resets_at: from_unix(info["resetsAt"]),
      raw: payload,
      sampled_at: DateTime.utc_now()
    })
    |> Repo.insert!()
    |> tap(&broadcast({:usage_sample, &1}))
  end

  defp from_unix(nil), do: nil

  defp from_unix(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp from_unix(_), do: nil

  # -- gauges -----------------------------------------------------------------------

  @doc "Latest sample per source (gauge inputs)."
  def latest_samples do
    for source <- ["oauth_api", "rate_limit_event"], into: %{} do
      sample =
        from(s in Sample,
          where: s.source == ^source,
          order_by: [desc: s.sampled_at],
          limit: 1
        )
        |> Repo.one()

      {source, sample}
    end
  end

  defdelegate opus_hours_this_week, to: Harness.Runs
  defdelegate overflow_usd_this_week, to: Harness.Runs

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Harness.PubSub, @topic, message)
  end
end
