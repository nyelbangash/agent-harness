defmodule Harness.GitHub do
  @moduledoc """
  Issue pipeline context: mirrored issues, triage decisions, plan packets,
  and per-repo poll bookkeeping. Every pipeline-visible change broadcasts
  `{:issue_updated, issue}` on the `"issues"` topic.
  """

  import Ecto.Query

  alias Harness.GitHub.{Issue, Plan, RepoState, TriageDecision, TriageOutcome}
  alias Harness.Repo

  @topic "issues"

  def subscribe, do: Phoenix.PubSub.subscribe(Harness.PubSub, @topic)

  # -- issues -----------------------------------------------------------------

  def get_issue!(id), do: Repo.get!(Issue, id)

  def get_issue_by(repo, number), do: Repo.get_by(Issue, repo: repo, number: number)

  @doc """
  Upsert an issue from a GitHub API payload. Returns `{:new | :updated | :unchanged, issue}` —
  the poller enqueues triage only for `:new`/`:updated` (keyed on GitHub's `updated_at`).
  """
  def upsert_issue(repo_name, %{"number" => number} = payload) do
    attrs = %{
      repo: repo_name,
      number: number,
      github_id: payload["id"],
      title: payload["title"] || "(untitled)",
      body: payload["body"],
      state: payload["state"] || "open",
      labels:
        payload["labels"] |> List.wrap() |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1),
      author: get_in(payload, ["user", "login"]),
      url: payload["html_url"],
      comments_count: payload["comments"] || 0,
      github_updated_at: parse_time(payload["updated_at"]),
      last_synced_at: DateTime.utc_now()
    }

    case get_issue_by(repo_name, number) do
      nil ->
        issue = %Issue{} |> Issue.changeset(attrs) |> Repo.insert!()
        broadcast(issue)
        {:new, issue}

      %Issue{} = existing ->
        if changed?(existing, attrs) do
          issue = existing |> Issue.changeset(attrs) |> Repo.update!()
          broadcast(issue)
          {:updated, issue}
        else
          {:unchanged,
           existing |> Issue.changeset(%{last_synced_at: attrs.last_synced_at}) |> Repo.update!()}
        end
    end
  end

  @doc """
  Self-acknowledge a GitHub update the harness itself caused (e.g. posting a
  plan comment): advance the stored `github_updated_at` so the next poll does
  not read our own write as operator activity and re-enqueue the pipeline
  (the #4 feedback loop, issue #28).
  """
  def acknowledge_self_update!(%Issue{} = issue, updated_at_iso) do
    case DateTime.from_iso8601(updated_at_iso) do
      {:ok, dt, _} ->
        if is_nil(issue.github_updated_at) or DateTime.after?(dt, issue.github_updated_at) do
          issue |> Issue.changeset(%{github_updated_at: dt}) |> Repo.update!()
        else
          issue
        end

      _ ->
        issue
    end
  end

  defp changed?(existing, attrs) do
    not same_instant?(existing.github_updated_at, attrs.github_updated_at) or
      existing.state != attrs.state or existing.labels != attrs.labels
  end

  # struct equality is wrong for DateTimes round-tripped through the DB
  # (microsecond precision differs); compare instants
  defp same_instant?(nil, nil), do: true
  defp same_instant?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same_instant?(_, _), do: false

  defp parse_time(nil), do: nil

  defp parse_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  @doc "Move an issue through the pipeline and broadcast."
  def transition!(%Issue{} = issue, pipeline_state) do
    previous = issue.pipeline_state
    issue = issue |> Issue.changeset(%{pipeline_state: pipeline_state}) |> Repo.update!()
    broadcast(issue)

    # notify once per failure, deduped over a short window: an Oban retry
    # re-enters planning→failed, so `previous != "failed"` alone would double-fire
    if pipeline_state == "failed" and previous != "failed" and notify_failure?(issue.id) do
      Harness.Notify.notify(
        :run_failed,
        "Run failed for #{issue.repo}##{issue.number}: #{issue.title}"
      )
    end

    issue
  end

  @failed_notify_window 600

  defp notify_failure?(issue_id) do
    key = {__MODULE__, :last_failed_notify, issue_id}
    now = System.system_time(:second)

    if now - :persistent_term.get(key, 0) > @failed_notify_window do
      :persistent_term.put(key, now)
      true
    else
      false
    end
  end

  @doc "Issues grouped by board column, newest activity first (drives IssuesLive)."
  def board do
    from(i in Issue, order_by: [desc: i.github_updated_at, desc: i.id])
    |> Repo.all()
    |> Enum.group_by(&Issue.column(&1.pipeline_state))
  end

  @doc "plan_ready and recently-failed issues (the Overview \"needs you\" queue)."
  def needs_attention(limit \\ 20) do
    from(i in Issue,
      where: i.pipeline_state in ["plan_ready", "failed"],
      order_by: [desc: i.updated_at],
      limit: ^limit,
      preload: [plans: ^from(p in Plan, where: p.status == "ready", order_by: [desc: p.id])]
    )
    |> Repo.all()
  end

  @doc """
  Promote an issue to the auto lane. Transitions to "implementing", broadcasts
  the change so OverviewLive re-renders immediately, and inserts an
  ImplementWorker job with `promoted: true`. Guards against double-promotion:
  if an active implement job already exists for the issue, returns
  `{:already_queued, issue}` without inserting a second job.
  """
  def promote_to_auto(issue_id) do
    issue = get_issue!(issue_id)

    active? =
      from(j in Oban.Job,
        where:
          j.worker == "Harness.GitHub.ImplementWorker" and
            j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("json_extract(?, '$.issue_id') = ?", j.args, ^issue.id),
        limit: 1
      )
      |> Repo.exists?()

    if active? do
      {:already_queued, issue}
    else
      issue = transition!(issue, "implementing")

      %{issue_id: issue.id, promoted: true}
      |> Harness.GitHub.ImplementWorker.new()
      |> Oban.insert()

      {:ok, issue}
    end
  end

  @doc "True when a triage/plan/implement Oban job is already active for the issue."
  def active_pipeline_job?(issue_id) do
    Repo.exists?(
      from j in Oban.Job,
        where:
          j.worker in [
            "Harness.GitHub.TriageWorker",
            "Harness.GitHub.PlanWorker",
            "Harness.GitHub.ImplementWorker"
          ] and
            j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("json_extract(?, '$.issue_id') = ?", j.args, ^issue_id)
    )
  end

  # -- triages ----------------------------------------------------------------

  def record_triage!(attrs) do
    triage = %TriageDecision{} |> TriageDecision.changeset(attrs) |> Repo.insert!()

    if issue = Repo.get(Issue, triage.issue_id), do: broadcast(issue)
    triage
  end

  def latest_triage(issue_id) do
    from(t in TriageDecision, where: t.issue_id == ^issue_id, order_by: [desc: t.id], limit: 1)
    |> Repo.one()
  end

  @doc """
  Insert exactly one outcome row per issue (idempotent — unique index on issue_id,
  on_conflict: :nothing).
  """
  def record_triage_outcome!(attrs) do
    %TriageOutcome{}
    |> TriageOutcome.changeset(attrs)
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:issue_id])
  end

  # -- plans ------------------------------------------------------------------

  @doc """
  After posting a harness-authored comment, advance `github_updated_at` in the
  DB to match the comment's `created_at`. This prevents the next poll sweep from
  seeing the comment-induced bump as operator activity.
  """
  def acknowledge_comment_timestamp!(issue, created_at_iso) do
    case DateTime.from_iso8601(created_at_iso) do
      {:ok, dt, _} ->
        issue
        |> Issue.changeset(%{github_updated_at: dt})
        |> Repo.update!()

      _ ->
        issue
    end
  end

  def record_plan!(attrs) do
    issue_id = Map.fetch!(attrs, :issue_id)

    from(p in Plan, where: p.issue_id == ^issue_id and p.status == "ready")
    |> Repo.update_all(set: [status: "superseded"])

    %Plan{} |> Plan.changeset(attrs) |> Repo.insert!()
  end

  def ready_plan(issue_id) do
    from(p in Plan, where: p.issue_id == ^issue_id and p.status == "ready", limit: 1)
    |> Repo.one()
  end

  # -- repo states --------------------------------------------------------------

  def repo_state(repo_name) do
    Repo.get_by(RepoState, repo: repo_name) ||
      %RepoState{} |> RepoState.changeset(%{repo: repo_name}) |> Repo.insert!()
  end

  def update_repo_state!(%RepoState{} = state, attrs) do
    state |> RepoState.changeset(attrs) |> Repo.update!()
  end

  defp broadcast(issue) do
    Phoenix.PubSub.broadcast(Harness.PubSub, @topic, {:issue_updated, issue})
  end
end
