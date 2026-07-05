defmodule Harness.Runs do
  @moduledoc """
  Run lifecycle context. Runs broadcast on `"runs"` (`{:run_started, run}` /
  `{:run_updated, run}`); individual events broadcast on `"runs:{id}"`
  (`{:run_event, event}`).

  `execute/1` is the single entry point workers use — it resolves the
  configured `Harness.Runs.Runner` implementation (the real CLI in dev/prod,
  a fake in tests).
  """

  import Ecto.Query

  alias Harness.Repo
  alias Harness.Runs.{Run, RunEvent, RunSpec}

  @topic "runs"

  def subscribe, do: Phoenix.PubSub.subscribe(Harness.PubSub, @topic)
  def subscribe(run_id), do: Phoenix.PubSub.subscribe(Harness.PubSub, "#{@topic}:#{run_id}")

  # -- lifecycle ----------------------------------------------------------------

  @doc "Execute a RunSpec through the configured runner implementation."
  def execute(%RunSpec{} = spec) do
    runner = Application.get_env(:harness, :runner, Harness.Runs.Runner.ClaudeCLI)
    runner.execute(spec, [])
  end

  def get_run!(id), do: Repo.get!(Run, id)

  @doc """
  Slot occupancy and waiting depth per Oban queue, in config order.

  `limits` defaults to the configured queues (keyword of queue → limit);
  returns `[]` when Oban runs queueless (tests pass limits explicitly).
  """
  def queue_stats(limits \\ nil) do
    limits = limits || Application.get_env(:harness, Oban, [])[:queues] || []

    counts =
      from(j in "oban_jobs",
        where: j.state in ["executing", "available", "scheduled", "retryable"],
        group_by: [j.queue, j.state],
        select: {j.queue, j.state, count(j.id)}
      )
      |> Repo.all()
      |> Enum.group_by(fn {queue, _state, _n} -> queue end)

    for {queue, limit} <- limits do
      name = Atom.to_string(queue)
      rows = Map.get(counts, name, [])
      running = for({_, "executing", n} <- rows, do: n) |> Enum.sum()
      waiting = for({_, state, n} <- rows, state != "executing", do: n) |> Enum.sum()

      %{
        queue: name,
        label: queue_label(name),
        limit: normalize_limit(limit),
        running: running,
        waiting: waiting
      }
    end
  end

  defp queue_label(name), do: name

  defp normalize_limit(limit) when is_integer(limit), do: limit
  defp normalize_limit(opts) when is_list(opts), do: Keyword.get(opts, :limit, 1)

  def create_run!(attrs) do
    run = %Run{} |> Run.changeset(attrs) |> Repo.insert!()
    broadcast({:run_started, run})
    run
  end

  def update_run!(%Run{} = run, attrs) do
    run = run |> Run.changeset(attrs) |> Repo.update!()
    broadcast({:run_updated, run})
    run
  end

  def next_event_seq(run_id) do
    (Repo.one(from e in RunEvent, where: e.run_id == ^run_id, select: max(e.seq)) || 0) + 1
  end

  @doc "Broadcast live counter state for a running row (turn count mid-run)."
  def broadcast_counters(run_id, turns) do
    broadcast({:run_counters, run_id, turns})
  end

  @doc "Append one decoded NDJSON event and broadcast it on the run's topic."
  def append_event!(%Run{} = run, seq, type, payload) do
    event =
      %RunEvent{}
      |> RunEvent.changeset(%{
        run_id: run.id,
        seq: seq,
        type: type,
        payload: payload,
        at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Phoenix.PubSub.broadcast(Harness.PubSub, "#{@topic}:#{run.id}", {:run_event, event})
    event
  end

  # -- kill switches --------------------------------------------------------------

  @doc "Kill one running session (UI kill button)."
  def kill(run_id) do
    case Registry.lookup(Harness.Runs.Registry, run_id) do
      [{pid, _}] -> safe_kill(pid)
      [] -> {:error, :not_running}
    end
  end

  @doc "Master kill: every registered live run."
  def kill_all do
    Registry.select(Harness.Runs.Registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(&safe_kill/1)
  end

  # the registry lookup races run completion — a server that finalized between
  # lookup and call exits the caller with :noproc/:normal; that's a run that
  # no longer needs killing, not an error
  defp safe_kill(pid) do
    Harness.Runs.RunServer.kill(pid)
  catch
    :exit, _ -> {:error, :not_running}
  end

  # -- queries ----------------------------------------------------------------

  def recent_runs(limit \\ 30) do
    from(r in Run, order_by: [desc: r.id], limit: ^limit) |> Repo.all()
  end

  def running_runs do
    from(r in Run, where: r.status in ["running", "verifying", "pushing", "opening_pr"])
    |> Repo.all()
  end

  @doc "Error string from the most recent terminal (failed/killed) run for an issue, or nil."
  def latest_terminal_run_error(issue_id) do
    from(r in Run,
      where: r.issue_id == ^issue_id and r.status in ["failed", "killed"],
      order_by: [desc: r.id],
      limit: 1,
      select: r.error
    )
    |> Repo.one()
  end

  @doc "Kind of the most recent run for an issue, or nil if none exists."
  def latest_issue_run_kind(issue_id) do
    from(r in Run,
      where: r.issue_id == ^issue_id,
      order_by: [desc: r.id],
      limit: 1,
      select: r.kind
    )
    |> Repo.one()
  end

  def active_implement_status(issue_id) do
    from(r in Run,
      where:
        r.issue_id == ^issue_id and r.kind == "implement" and
          r.status not in ["succeeded", "failed", "killed"],
      order_by: [desc: r.id],
      limit: 1,
      select: r.status
    )
    |> Repo.one()
  end

  def events(run_id) do
    from(e in RunEvent, where: e.run_id == ^run_id, order_by: e.seq) |> Repo.all()
  end

  @doc "Trailing-7-day Opus wall-clock hours (vs budgets.opus_hours_weekly_cap)."
  def opus_hours_this_week do
    week_ago = DateTime.add(DateTime.utc_now(), -7, :day)

    from(r in Run,
      where:
        not is_nil(r.started_at) and not is_nil(r.ended_at) and
          r.started_at > ^week_ago and like(r.model, "%opus%")
    )
    |> Repo.all()
    |> Enum.reduce(0.0, fn run, acc ->
      acc + DateTime.diff(run.ended_at, run.started_at, :second) / 3600
    end)
  end

  @doc "Trailing-7-day estimated overflow spend (runs flagged used_overage)."
  def overflow_usd_this_week do
    week_ago = DateTime.add(DateTime.utc_now(), -7, :day)

    from(r in Run,
      where: r.used_overage and r.inserted_at > ^week_ago,
      select: coalesce(sum(r.cost_estimate), 0.0)
    )
    |> Repo.one()
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Harness.PubSub, @topic, message)
  end
end
