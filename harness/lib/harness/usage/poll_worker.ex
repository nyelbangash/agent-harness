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
            previous_mode = Harness.Usage.current_mode()
            Harness.Usage.record_oauth_sample!(attrs)
            notify_transitions(previous_mode, policy)
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

  # notify when the usage-derived gate tightens, or a weekly cap crosses the
  # warning fraction (spec §9.6)
  defp notify_transitions(previous_mode, policy) do
    new_mode = Harness.Usage.current_mode()

    if tightened?(previous_mode, new_mode) do
      Harness.Notify.notify(
        :gate_tripped,
        "Utilization gate tightened: #{previous_mode} → #{new_mode}"
      )
    end

    warn = policy.notify && policy.notify.budget_warn_fraction

    if warn do
      opus = Harness.Usage.opus_hours_this_week() / policy.budgets.opus_hours_weekly_cap

      overflow =
        (Harness.Usage.overflow_usd_this_week() || 0.0) / policy.budgets.overflow_usd_weekly_cap

      cond do
        opus >= warn ->
          warn_once(:opus, "Opus hours at #{round(opus * 100)}% of the weekly cap")

        overflow >= warn ->
          warn_once(:overflow, "Overflow spend at #{round(overflow * 100)}% of the weekly cap")

        true ->
          :ok
      end
    end

    :ok
  end

  # at most one budget warning per cap per hour (the poller runs every ~10 min)
  defp warn_once(cap, message) do
    key = {__MODULE__, :last_budget_warn, cap}
    last = :persistent_term.get(key, 0)
    now = System.system_time(:second)

    if now - last > 3600 do
      :persistent_term.put(key, now)
      Harness.Notify.notify(:budget_warning, message)
    end

    :ok
  end

  @order [:full_auto, :defer_ideation, :plan_only, :pause]
  defp tightened?(prev, new) do
    Enum.find_index(@order, &(&1 == new)) > Enum.find_index(@order, &(&1 == prev))
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
