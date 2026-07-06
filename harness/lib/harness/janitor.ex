defmodule Harness.Janitor do
  @moduledoc """
  Level-triggered reconciliation (cron, every minute). Edge-triggered logic
  elsewhere can drop edges on crashes or dedupe — the janitor makes those
  states self-heal:

    * runs stuck at `running` with no live RunServer (daemon died mid-run) —
      finalize as failed; SIGTERM the recorded os_pid only if it is still a
      claude process (pids get recycled)
    * issues wedged in `triaging`/`planning` with no incomplete Oban job and
      no live run — send back to `incoming` + re-enqueue triage
    * issues whose GitHub `updated_at` is newer than their latest triage
      (update arrived while in flight; the poller's edge was consumed) —
      re-enqueue triage once they're back in a settled state
  """

  use Oban.Worker, queue: :ops, max_attempts: 1, unique: [period: 55]

  require Logger
  import Ecto.Query

  alias Harness.GitHub
  alias Harness.GitHub.{Issue, TriageDecision}
  alias Harness.Repo
  alias Harness.Runs.Run

  @impl Oban.Worker
  def perform(_job) do
    reap_orphaned_runs()
    unwedge_stuck_issues()
    retriage_updated_issues()
    resume_stalled_ideation()
    auto_clear_stale_issues()
    reconcile_queues()
    :ok
  end

  defp reap_orphaned_runs do
    for run <- Repo.all(from(r in Run, where: r.status == "running")) do
      case Registry.lookup(Harness.Runs.Registry, run.id) do
        [_ | _] ->
          :ok

        [] ->
          Logger.warning("janitor: run #{run.id} is 'running' with no server — reaping")
          maybe_kill_claude(run.os_pid)

          Harness.Runs.update_run!(run, %{
            status: "failed",
            error: "reaped: no live run server (daemon restarted mid-run?)",
            ended_at: DateTime.utc_now()
          })
      end
    end
  end

  defp maybe_kill_claude(nil), do: :ok

  defp maybe_kill_claude(os_pid) do
    pid = Integer.to_string(os_pid)

    case System.cmd("ps", ["-p", pid, "-o", "command="], stderr_to_stdout: true) do
      {command, 0} ->
        if command =~ "claude" do
          System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
        end

      _ ->
        :ok
    end
  end

  defp unwedge_stuck_issues do
    stuck =
      Repo.all(
        from(i in Issue,
          where: i.pipeline_state in ["triaging", "planning"] and i.state == "open"
        )
      )

    for issue <- stuck,
        not has_incomplete_job?(issue.id),
        not has_live_run?(issue.id) do
      Logger.warning(
        "janitor: issue #{issue.repo}##{issue.number} wedged in #{issue.pipeline_state} — resetting"
      )

      issue = Harness.GitHub.transition!(issue, "incoming")
      %{issue_id: issue.id} |> Harness.GitHub.TriageWorker.new() |> Oban.insert()
    end
  end

  defp retriage_updated_issues do
    outdated =
      Repo.all(
        from(i in Issue,
          where: i.state == "open" and i.pipeline_state in ["triaged", "plan_ready", "failed"],
          join: t in subquery(latest_triages()),
          on: t.issue_id == i.id,
          where: i.github_updated_at > t.latest_at
        )
      )

    for issue <- outdated,
        # the #28 self-ack advances github_updated_at past the triage row —
        # without this check the janitor reads our own plan comment as
        # operator activity and loops (plan -> comment -> ack -> re-triage)
        not Harness.GitHub.harness_caused_update?(issue) do
      Logger.info(
        "janitor: issue #{issue.repo}##{issue.number} changed since triage — re-enqueueing"
      )

      %{issue_id: issue.id} |> Harness.GitHub.TriageWorker.new() |> Oban.insert()
    end
  end

  # a running session whose iteration/critique chain broke (job exhausted
  # attempts, or the daemon died between iterations) has no incomplete ideate
  # job — re-enqueue one so the tree keeps growing
  defp resume_stalled_ideation do
    for session <- Harness.Ideation.running_sessions(),
        not has_incomplete_ideate_job?(session.id) do
      Logger.warning("janitor: ideation session #{session.id} stalled — resuming")
      Harness.Ideation.enqueue_iteration(session)
    end
  end

  defp has_incomplete_ideate_job?(session_id) do
    incomplete = ~w(available scheduled executing retryable)

    Repo.exists?(
      from(j in Oban.Job,
        where:
          j.worker in ["Harness.Ideation.IterationWorker", "Harness.Ideation.CritiqueWorker"] and
            j.state in ^incomplete and
            fragment("json_extract(?, '$.session_id') = ?", j.args, ^session_id)
      )
    )
  end

  # terminal-state cards (done/failed/skipped) sitting untouched past the
  # configured threshold auto-dismiss off the board (issue #76). Aged against
  # `terminal_at` (stamped once, when the issue lands in a terminal state) —
  # not `updated_at`, which every ~2-minute poll bumps via upsert_issue's
  # :unchanged branch even when nothing about the issue actually changed.
  defp auto_clear_stale_issues do
    days = Harness.Policy.get().board.auto_clear_after_days
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    stale_ids =
      Repo.all(
        from(i in Issue,
          where:
            i.pipeline_state in ["done", "failed", "skipped"] and
              is_nil(i.dismissed_at) and
              not is_nil(i.terminal_at) and
              i.terminal_at < ^cutoff,
          select: i.id
        )
      )

    if stale_ids != [] do
      Logger.info("janitor: auto-dismissing #{length(stale_ids)} stale terminal issue(s)")
      GitHub.dismiss_issues!(stale_ids)
    end
  end

  defp latest_triages do
    from(t in TriageDecision,
      group_by: t.issue_id,
      select: %{issue_id: t.issue_id, latest_at: max(t.inserted_at)}
    )
  end

  defp has_incomplete_job?(issue_id) do
    incomplete = ~w(available scheduled executing retryable scheduled)

    Repo.exists?(
      from(j in Oban.Job,
        where:
          j.worker in ["Harness.GitHub.TriageWorker", "Harness.GitHub.PlanWorker"] and
            j.state in ^incomplete and
            fragment("json_extract(?, '$.issue_id') = ?", j.args, ^issue_id)
      )
    )
  end

  defp has_live_run?(issue_id) do
    Repo.all(from(r in Run, where: r.issue_id == ^issue_id and r.status == "running"))
    |> Enum.any?(fn run ->
      Registry.lookup(Harness.Runs.Registry, run.id) != []
    end)
  end

  defp reconcile_queues do
    conf = Oban.config()
    configured = Application.fetch_env!(:harness, Oban)[:queues] || []
    running_names = conf.queues |> Keyword.keys() |> MapSet.new()

    for {queue, opts} <- configured, queue not in running_names do
      limit = if is_integer(opts), do: opts, else: Keyword.get(opts, :limit, 1)

      Logger.warning(
        "janitor: starting queue #{queue} at runtime — restart recommended at next quiet moment"
      )

      # In testing mode Oban.config().queues is [] so every queue looks absent;
      # calling start_queue would launch real producers that can't check out sandbox connections.
      unless conf.testing in [:manual, :inline] do
        Oban.start_queue(queue: queue, limit: limit)
      end
    end
  end
end
