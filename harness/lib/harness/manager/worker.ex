defmodule Harness.Manager.Worker do
  @moduledoc """
  Continuous supervisory loop over all pipeline work (cron: every minute,
  self-throttled to `manager.poll_minutes`, default 5).

  Detects six anomaly classes invisible to the Janitor, applies Tier-0 safe
  repairs, and sends Tier-1 proposals to the operator when authority allows.
  Never autonomously kills a model run — that is always Tier-1 (propose only).

  Relationship to Janitor: the Janitor covers orphaned runs and issues wedged
  in triaging/planning. This worker covers the classes the Janitor does not:
  implementing-state strandings, ghost Oban jobs, stall-by-event-freshness,
  loop signatures, artifact drift, and telemetry/stale-code lamps.
  """

  use Oban.Worker, queue: :ops, max_attempts: 1, unique: [period: 55]

  require Logger
  import Ecto.Query

  alias Harness.GitHub.Issue
  alias Harness.Manager.LampServer
  alias Harness.Repo
  alias Harness.Runs.{Run, RunEvent}

  @model_workers ~w(
    Harness.GitHub.TriageWorker
    Harness.GitHub.PlanWorker
    Harness.GitHub.ImplementWorker
    Harness.GitHub.ReviewWorker
    Harness.GitHub.RespondWorker
  )

  @impl Oban.Worker
  def perform(_job) do
    policy = Harness.Policy.get()

    if !policy.manager.enabled do
      :ok
    else
      case should_sweep?(policy) do
        {:snooze, s} -> {:snooze, s}
        :ok -> do_sweep(policy)
      end
    end
  end

  defp should_sweep?(policy) do
    case LampServer.last_sweep_at() do
      nil ->
        :ok

      last_at ->
        elapsed = DateTime.diff(DateTime.utc_now(), last_at, :second)
        interval = policy.manager.poll_minutes * 60

        if elapsed < interval do
          {:snooze, interval - elapsed}
        else
          :ok
        end
    end
  end

  defp do_sweep(policy) do
    loops = detect_loop_signatures(policy)
    ghosts = detect_ghost_jobs(policy)
    stalled = detect_stalled_runs(policy)
    stranded = detect_stranded_states()
    drifted = detect_artifact_drift()
    telemetry_silent = detect_telemetry_silence(policy)
    stale_code = detect_stale_code()

    repairs = apply_tier0_repairs(ghosts, stranded, drifted)

    proposals =
      if policy.manager.authority in ["tier1", "tier2"] do
        send_tier1_proposals(loops, stalled)
      else
        []
      end

    update_lamps(loops, ghosts, stalled, stranded, drifted, telemetry_silent, stale_code)

    append_snapshot(
      loops,
      ghosts,
      stalled,
      stranded,
      drifted,
      telemetry_silent,
      stale_code,
      repairs,
      proposals
    )

    LampServer.record_sweep()

    :ok
  end

  # -- detection --------------------------------------------------------------

  defp detect_loop_signatures(policy) do
    window = DateTime.add(DateTime.utc_now(), -policy.manager.loop_window_minutes * 60, :second)
    threshold = policy.manager.loop_triage_threshold

    from(r in Run,
      where: r.kind == "triage" and r.inserted_at >= ^window and not is_nil(r.issue_id),
      group_by: r.issue_id,
      having: count(r.id) >= ^threshold,
      select: {r.issue_id, count(r.id)}
    )
    |> Repo.all()
  end

  defp detect_ghost_jobs(policy) do
    cutoff = DateTime.add(DateTime.utc_now(), -policy.manager.ghost_job_grace_seconds, :second)

    from(j in Oban.Job,
      where: j.state == "executing" and j.worker in ^@model_workers and j.attempted_at < ^cutoff
    )
    |> Repo.all()
    |> Enum.filter(fn job ->
      issue_id = job.args["issue_id"]
      not has_live_run_for_issue?(issue_id)
    end)
  end

  defp detect_stalled_runs(policy) do
    cutoff = DateTime.add(DateTime.utc_now(), -policy.manager.stall_minutes * 60, :second)

    from(r in Run, where: r.status == "running" and r.kind != "manager")
    |> Repo.all()
    |> Enum.filter(fn run ->
      Registry.lookup(Harness.Runs.Registry, run.id) != [] and stalled?(run, cutoff)
    end)
  end

  defp stalled?(run, cutoff) do
    latest_event_at =
      Repo.one(from(e in RunEvent, where: e.run_id == ^run.id, select: max(e.at)))

    baseline = latest_event_at || run.started_at
    not is_nil(baseline) and DateTime.compare(baseline, cutoff) == :lt
  end

  defp detect_stranded_states do
    from(i in Issue,
      where: i.pipeline_state in ["implementing"] and i.state == "open"
    )
    |> Repo.all()
    |> Enum.reject(fn issue ->
      has_incomplete_implement_job?(issue.id) or has_live_run?(issue.id)
    end)
  end

  defp detect_artifact_drift do
    from(i in Issue,
      join: p in assoc(i, :plans),
      where:
        i.pipeline_state in ["incoming", "triaged"] and i.state == "open" and
          p.status == "ready",
      distinct: true
    )
    |> Repo.all()
  end

  defp detect_telemetry_silence(policy) do
    n = policy.manager.telemetry_silence_samples

    recent =
      from(s in Harness.Usage.Sample,
        where: s.source == "oauth_api",
        order_by: [desc: s.inserted_at],
        limit: ^n
      )
      |> Repo.all()

    Enum.count(recent) >= n and
      Enum.all?(recent, fn s ->
        is_nil(s.five_hour_utilization) and is_nil(s.seven_day_utilization)
      end)
  end

  defp detect_stale_code do
    case Harness.Health.check() do
      {:ok, %{"stale_code" => true}} -> true
      {:error, %{"stale_code" => true}} -> true
      _ -> false
    end
  end

  # -- tier-0 repairs ---------------------------------------------------------

  defp apply_tier0_repairs(ghosts, stranded, drifted) do
    ghost_repairs = Enum.flat_map(ghosts, &cancel_ghost_job/1)
    stranded_repairs = Enum.flat_map(stranded, &normalize_stranded/1)
    drift_repairs = Enum.flat_map(drifted, &repair_artifact_drift/1)

    ghost_repairs ++ stranded_repairs ++ drift_repairs
  end

  defp cancel_ghost_job(job) do
    Logger.warning("manager: cancelling ghost Oban job #{job.id} (worker=#{job.worker})")

    case Oban.cancel_job(job.id) do
      :ok ->
        [%{type: "ghost_job_cancelled", job_id: job.id, worker: job.worker}]

      {:error, reason} ->
        Logger.warning("manager: failed to cancel job #{job.id}: #{inspect(reason)}")
        []
    end
  end

  defp normalize_stranded(issue) do
    Logger.warning(
      "manager: issue #{issue.repo}##{issue.number} stranded in #{issue.pipeline_state} — resetting"
    )

    issue = Harness.GitHub.transition!(issue, "incoming")
    %{issue_id: issue.id} |> Harness.GitHub.TriageWorker.new() |> Oban.insert()

    [%{type: "stranded_state_normalized", issue_id: issue.id, from: "implementing"}]
  end

  defp repair_artifact_drift(issue) do
    Logger.info(
      "manager: issue #{issue.repo}##{issue.number} has a ready plan but state=#{issue.pipeline_state} — advancing"
    )

    Harness.GitHub.transition!(issue, "plan_ready")

    [%{type: "artifact_drift_repaired", issue_id: issue.id, from: issue.pipeline_state}]
  end

  # -- tier-1 proposals -------------------------------------------------------

  defp send_tier1_proposals(loops, stalled) do
    loop_proposals =
      Enum.map(loops, fn {issue_id, count} ->
        msg = "Loop signature on issue ##{issue_id}: #{count} triage runs in the window"
        Logger.warning("manager: tier-1 proposal — #{msg}")
        Harness.Notify.notify(:manager_proposal, msg)
        %{type: "loop_signature", issue_id: issue_id, count: count}
      end)

    stall_proposals =
      Enum.map(stalled, fn run ->
        msg =
          "Stalled run ##{run.id} (#{run.kind}) — no events for >#{div(DateTime.diff(DateTime.utc_now(), run.started_at || DateTime.utc_now(), :second), 60)} min"

        Logger.warning("manager: tier-1 proposal — #{msg}")
        Harness.Notify.notify(:manager_proposal, msg)
        %{type: "stalled_run", run_id: run.id}
      end)

    loop_proposals ++ stall_proposals
  end

  # -- lamps ------------------------------------------------------------------

  defp update_lamps(loops, ghosts, stalled, stranded, drifted, telemetry_silent, stale_code) do
    lamp_or_clear(:loop_signature, loops != [], format_loops(loops))
    lamp_or_clear(:wedged_lane, ghosts != [], format_ghosts(ghosts))
    lamp_or_clear(:stalled_run, stalled != [], format_stalled(stalled))
    lamp_or_clear(:stranded_state, stranded != [], format_stranded(stranded))
    lamp_or_clear(:artifact_drift, drifted != [], format_drifted(drifted))
    lamp_or_clear(:telemetry_silence, telemetry_silent, nil)
    lamp_or_clear(:stale_code, stale_code, nil)
  end

  defp lamp_or_clear(lamp, true, detail), do: LampServer.set(lamp, detail)
  defp lamp_or_clear(lamp, false, _detail), do: LampServer.clear(lamp)

  defp format_loops(loops) do
    Enum.map_join(loops, ", ", fn {id, n} -> "##{id}×#{n}" end)
  end

  defp format_ghosts(ghosts) do
    Enum.map_join(ghosts, ", ", fn j -> "job #{j.id}" end)
  end

  defp format_stalled(stalled) do
    Enum.map_join(stalled, ", ", fn r -> "##{r.id}" end)
  end

  defp format_stranded(stranded) do
    Enum.map_join(stranded, ", ", fn i -> "##{i.id}" end)
  end

  defp format_drifted(drifted) do
    Enum.map_join(drifted, ", ", fn i -> "##{i.id}" end)
  end

  # -- snapshot ---------------------------------------------------------------

  defp append_snapshot(
         loops,
         ghosts,
         stalled,
         stranded,
         drifted,
         telemetry_silent,
         stale_code,
         repairs,
         proposals
       ) do
    run = ensure_manager_run()
    seq = Harness.Runs.next_event_seq(run.id)

    Harness.Runs.append_event!(run, seq, "system", %{
      "sweep_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "anomalies" => %{
        "loop_signatures" => length(loops),
        "ghost_jobs" => length(ghosts),
        "stalled_runs" => length(stalled),
        "stranded_states" => length(stranded),
        "artifact_drifts" => length(drifted),
        "telemetry_silent" => telemetry_silent,
        "stale_code" => stale_code
      },
      "tier0_repairs" => repairs,
      "tier1_proposals" => proposals
    })
  end

  defp ensure_manager_run do
    case :persistent_term.get(:harness_manager_run_id, nil) do
      nil ->
        create_manager_run()

      id ->
        case Repo.get(Run, id) do
          nil -> create_manager_run()
          run -> run
        end
    end
  end

  defp create_manager_run do
    run =
      Harness.Runs.create_run!(%{
        kind: "manager",
        status: "running",
        model: "none",
        ref: "manager"
      })

    :persistent_term.put(:harness_manager_run_id, run.id)
    run
  end

  # -- helpers ----------------------------------------------------------------

  defp has_live_run_for_issue?(nil), do: true

  defp has_live_run_for_issue?(issue_id) do
    from(r in Run, where: r.issue_id == ^issue_id and r.status == "running")
    |> Repo.all()
    |> Enum.any?(fn run ->
      Registry.lookup(Harness.Runs.Registry, run.id) != []
    end)
  end

  defp has_incomplete_implement_job?(issue_id) do
    incomplete = ~w(available scheduled executing retryable)

    Repo.exists?(
      from(j in Oban.Job,
        where:
          j.worker in ["Harness.GitHub.ImplementWorker", "Harness.GitHub.ReviewWorker"] and
            j.state in ^incomplete and
            fragment("json_extract(?, '$.issue_id') = ?", j.args, ^issue_id)
      )
    )
  end

  defp has_live_run?(issue_id) do
    from(r in Run, where: r.issue_id == ^issue_id and r.status == "running")
    |> Repo.all()
    |> Enum.any?(fn run ->
      Registry.lookup(Harness.Runs.Registry, run.id) != []
    end)
  end
end
