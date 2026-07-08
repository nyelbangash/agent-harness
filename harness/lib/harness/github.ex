defmodule Harness.GitHub do
  @moduledoc """
  Issue pipeline context: mirrored issues, triage decisions, plan packets,
  and per-repo poll bookkeeping. Every pipeline-visible change broadcasts
  `{:issue_updated, issue}` on the `"issues"` topic.
  """

  import Ecto.Query

  alias Harness.GitHub.{
    Issue,
    Plan,
    PrCommentHandle,
    ProjectState,
    RepoState,
    TriageDecision,
    TriageOutcome
  }

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
    timestamp_advanced?(existing.github_updated_at, attrs.github_updated_at) or
      existing.state != attrs.state or existing.labels != attrs.labels
  end

  # GitHub list endpoints can serve snapshots that lag a just-posted comment;
  # a payload OLDER than what we stored is staleness, not an update — treating
  # it as changed regresses the stored timestamp and re-triggers the pipeline
  # (the #70 loop). Time only moves forward here.
  defp timestamp_advanced?(nil, nil), do: false
  defp timestamp_advanced?(nil, %DateTime{}), do: true
  defp timestamp_advanced?(%DateTime{}, nil), do: false

  defp timestamp_advanced?(%DateTime{} = stored, %DateTime{} = incoming),
    do: DateTime.compare(incoming, stored) == :gt

  defp parse_time(nil), do: nil

  defp parse_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  @doc """
  Move an issue through the pipeline and broadcast. Also clears `dismissed_at`
  — re-entering the pipeline is itself the un-dismiss signal, kept orthogonal
  to `@retriageable` (see `PollWorker`).

  Stamps `terminal_at` when landing on done/failed/skipped so the janitor's
  auto-clear can age off the pipeline's own clock instead of `updated_at`,
  which every poll bumps regardless of real GitHub activity (issue #76).
  """
  def transition!(%Issue{} = issue, pipeline_state) do
    previous = issue.pipeline_state

    terminal_at = if Issue.terminal?(pipeline_state), do: DateTime.utc_now(), else: nil

    issue =
      issue
      |> Issue.changeset(%{
        pipeline_state: pipeline_state,
        dismissed_at: nil,
        terminal_at: terminal_at
      })
      |> Repo.update!()

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

  @doc """
  Issues grouped by board column, newest activity first (drives IssuesLive).
  Dismissed issues are excluded — they remain in the `issues` table (the
  poller still finds them by repo+number) but never render.
  """
  def board do
    from(i in Issue,
      where: is_nil(i.dismissed_at),
      order_by: [desc: i.github_updated_at, desc: i.id]
    )
    |> Repo.all()
    |> Enum.group_by(&Issue.column(&1.pipeline_state))
  end

  @doc """
  Locally dismiss an issue from the board. Non-destructive: does not touch the
  GitHub issue or delete the row, so `PollWorker` still treats it as known
  (see `upsert_issue/2`) rather than re-triaging it as new.
  """
  def dismiss_issue!(%Issue{} = issue) do
    issue = issue |> Issue.changeset(%{dismissed_at: DateTime.utc_now()}) |> Repo.update!()
    broadcast(issue)
    issue
  end

  @doc "Bulk dismiss by id list; returns the updated issues."
  def dismiss_issues!(issue_ids) when is_list(issue_ids) do
    now = DateTime.utc_now()

    from(i in Issue, where: i.id in ^issue_ids)
    |> Repo.update_all(set: [dismissed_at: now, updated_at: now])

    issues = Repo.all(from(i in Issue, where: i.id in ^issue_ids))
    Enum.each(issues, &broadcast/1)
    issues
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

  @doc "True when a triage/plan/implement/review Oban job is already active for the issue."
  def active_pipeline_job?(issue_id) do
    Repo.exists?(
      from j in Oban.Job,
        where:
          j.worker in [
            "Harness.GitHub.TriageWorker",
            "Harness.GitHub.PlanWorker",
            "Harness.GitHub.ImplementWorker",
            "Harness.GitHub.ReviewWorker"
          ] and
            j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("json_extract(?, '$.issue_id') = ?", j.args, ^issue_id)
    )
  end

  @doc """
  True when an issue.s newest GitHub comment is harness-stamped and accounts
  for the current stored github_updated_at — i.e. the last thing that happened
  to this issue was the harness talking. Shared by the poller (:updated gate)
  and the janitor (retriage_updated_issues), which otherwise reads the #28
  self-acknowledgment as "changed since triage" and loops (the #75 mechanism:
  plan comment -> self-ack advances updated_at -> janitor re-triages).
  """
  def harness_caused_update?(%Issue{} = issue) do
    case Harness.GitHub.Client.newest_issue_comment(issue.repo, issue.number) do
      {:ok, %{"body" => body, "created_at" => created_at_iso}} ->
        Harness.GitHub.Provenance.harness_authored?(body) and
          comment_accounts_for_delta?(created_at_iso, issue)

      _ ->
        false
    end
  end

  defp comment_accounts_for_delta?(created_at_iso, issue) do
    case DateTime.from_iso8601(created_at_iso) do
      {:ok, comment_time, _} ->
        not is_nil(issue.github_updated_at) and
          DateTime.compare(comment_time, issue.github_updated_at) in [:gt, :eq]

      _ ->
        false
    end
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

  # -- project states -----------------------------------------------------------

  def project_state(owner, number) do
    Repo.get_by(ProjectState, owner: owner, number: number) ||
      %ProjectState{} |> ProjectState.changeset(%{owner: owner, number: number}) |> Repo.insert!()
  end

  def update_project_state!(%ProjectState{} = state, attrs) do
    state |> ProjectState.changeset(attrs) |> Repo.update!()
  end

  # -- pr comment handles -------------------------------------------------------

  @doc """
  Insert a `PrCommentHandle` with `on_conflict: :nothing`. Returns
  `{:inserted, handle}` when the row is new, or `:already_handled` when
  the unique constraint fired (the comment was already processed).
  Mirrors `record_triage_outcome!/1`.
  """
  def maybe_insert_pr_comment_handle!(attrs) do
    handle =
      %PrCommentHandle{}
      |> PrCommentHandle.changeset(attrs)
      |> Repo.insert!(
        on_conflict: :nothing,
        conflict_target: [:repo, :comment_id, :comment_type]
      )

    if is_nil(handle.id), do: :already_handled, else: {:inserted, handle}
  end

  @doc "Record the outcome action and run_id on a handle after RespondWorker completes."
  def update_pr_comment_handle!(%PrCommentHandle{} = handle, attrs) do
    handle |> PrCommentHandle.changeset(attrs) |> Repo.update!()
  end

  defp broadcast(issue) do
    Phoenix.PubSub.broadcast(Harness.PubSub, @topic, {:issue_updated, issue})
  end
end
