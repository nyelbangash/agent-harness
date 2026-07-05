defmodule Harness.GitHub.PollWorker do
  @moduledoc """
  Issue ingest (spec §4.1). Cron fires every minute; the worker early-exits
  unless `github.poll_minutes` has elapsed for a repo (hot-reload-friendly).
  ETag-conditional requests make idle polls free.

  Pipeline entry rules:
    * `human-only` label → `skipped`, zero model spend
    * new issues, and issues whose GitHub `updated_at` changed while parked
      in a restartable state → enqueue `TriageWorker`
    * issues that closed upstream while in flight → `done`
  """

  use Oban.Worker, queue: :ops, max_attempts: 1, unique: [period: 55]

  require Logger
  import Ecto.Query

  alias Harness.GitHub
  alias Harness.GitHub.{Client, Issue, Provenance}

  # states it is safe to re-triage from when the issue changes upstream
  @retriageable ~w(incoming triaged plan_ready failed skipped done)

  @impl Oban.Worker
  def perform(_job) do
    policy = Harness.Policy.get()

    with {:ok, login} <- assignee_login() do
      for repo <- policy.github.repos do
        poll_repo(repo, login, policy.github.poll_minutes)
      end

      :persistent_term.put({__MODULE__, :last_sweep_at}, System.system_time(:second))
    end

    :ok
  end

  defp assignee_login do
    case :persistent_term.get({__MODULE__, :login}, nil) do
      nil ->
        case Client.viewer_login() do
          {:ok, login} ->
            :persistent_term.put({__MODULE__, :login}, login)
            {:ok, login}

          {:error, reason} ->
            Logger.warning("could not resolve PAT owner login: #{inspect(reason)}")
            {:error, reason}
        end

      login ->
        {:ok, login}
    end
  end

  defp poll_repo(repo, login, poll_minutes) do
    state = GitHub.repo_state(repo.name)

    if due?(state, poll_minutes) do
      state =
        case Client.list_assigned_issues(repo.name, login, state.etag) do
          :not_modified ->
            GitHub.update_repo_state!(state, %{
              last_polled_at: DateTime.utc_now(),
              last_status: 304
            })

          {:ok, issues, etag} ->
            Enum.each(issues, &handle_issue(repo.name, &1))

            # absence-from-listing only means "closed" when the listing was
            # complete — at the page cap an open issue may simply be on page 2
            if length(issues) < 100, do: reconcile_closed(repo.name, issues)

            GitHub.update_repo_state!(state, %{
              etag: etag,
              last_polled_at: DateTime.utc_now(),
              last_status: 200
            })

          {:error, reason} ->
            Logger.warning("poll #{repo.name} failed: #{inspect(reason)}")

            GitHub.update_repo_state!(state, %{last_polled_at: DateTime.utc_now(), last_status: 0})
        end

      poll_pr_comments(repo.name, login, state)
      GitHub.update_repo_state!(state, %{pr_comments_since: DateTime.utc_now()})
    end
  end

  defp poll_pr_comments(repo_name, login, state) do
    since_dt = state.pr_comments_since || DateTime.add(DateTime.utc_now(), -86_400, :second)
    since_iso = DateTime.to_iso8601(since_dt)

    pr_open_issues =
      Harness.Repo.all(
        from(i in Issue,
          where:
            i.repo == ^repo_name and i.pipeline_state == "pr_open" and not is_nil(i.pr_number)
        )
      )

    for issue <- pr_open_issues do
      review_comments =
        case Client.list_pr_review_comments(repo_name, issue.pr_number, since_iso) do
          {:ok, comments} -> Enum.map(comments, &{&1, "review"})
          {:error, _} -> []
        end

      issue_comments =
        case Client.list_pr_issue_comments(repo_name, issue.pr_number, since_iso) do
          {:ok, comments} -> Enum.map(comments, &{&1, "issue"})
          {:error, _} -> []
        end

      for {comment, comment_type} <- review_comments ++ issue_comments do
        author = get_in(comment, ["user", "login"])
        body = comment["body"] || ""

        if author == login and not Provenance.harness_authored?(body) do
          attrs = %{
            repo: repo_name,
            pr_number: issue.pr_number,
            comment_id: comment["id"],
            comment_type: comment_type
          }

          case GitHub.maybe_insert_pr_comment_handle!(attrs) do
            {:inserted, handle} ->
              %{
                pr_comment_handle_id: handle.id,
                issue_id: issue.id,
                comment_body: body,
                comment_path: comment["path"],
                comment_line: comment["line"],
                comment_diff_hunk: comment["diff_hunk"]
              }
              |> Harness.GitHub.RespondWorker.new()
              |> Oban.insert()

            :already_handled ->
              :ok
          end
        end
      end

      check_pr_mergeability(repo_name, issue)
    end

    :ok
  end

  defp check_pr_mergeability(repo_name, issue) do
    case Client.get_pull_request(repo_name, issue.pr_number) do
      {:ok, %{mergeable_state: ms, head_ref: head_ref}}
      when ms in ["conflicting", "dirty"] ->
        if String.starts_with?(head_ref, "harness/") do
          Logger.info("PR #{repo_name}##{issue.pr_number} is #{ms}; re-enqueueing review")

          %{issue_id: issue.id, pr_number: issue.pr_number, round: 0, branch: head_ref}
          |> Harness.GitHub.ReviewWorker.new()
          |> Oban.insert()
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp due?(%{last_polled_at: nil}, _minutes), do: true

  defp due?(%{last_polled_at: last}, minutes) do
    DateTime.diff(DateTime.utc_now(), last, :second) >= minutes * 60 - 5
  end

  defp handle_issue(repo_name, payload) do
    {change, issue} = GitHub.upsert_issue(repo_name, payload)

    cond do
      "human-only" in issue.labels ->
        unless issue.pipeline_state == "skipped" do
          GitHub.transition!(issue, "skipped")
        end

      # the off-machine lane (GitHub Action) owns agent-cloud issues — don't
      # triage/implement them locally (spec §8: Mission Control observes this
      # lane on the board, it doesn't orchestrate it). Also stop any local work
      # already in flight when the label arrives mid-pipeline, or the local
      # session double-bills against the cloud Action.
      "agent-cloud" in issue.labels ->
        unless issue.pipeline_state in ~w(skipped done pr_open) do
          cancel_local_work(issue)
          GitHub.transition!(issue, "skipped")
        end

      change == :new ->
        enqueue_triage(issue)

      change == :updated and issue.pipeline_state in @retriageable ->
        unless harness_caused_update?(issue), do: enqueue_triage(issue)

      true ->
        :ok
    end
  end

  defp enqueue_triage(issue) do
    issue = GitHub.transition!(issue, "incoming")

    %{issue_id: issue.id}
    |> Harness.GitHub.TriageWorker.new()
    |> Oban.insert()
  end

  defp harness_caused_update?(issue) do
    case Client.newest_issue_comment(issue.repo, issue.number) do
      {:ok, %{"body" => body, "created_at" => created_at_iso}} ->
        Provenance.harness_authored?(body) and comment_accounts_for_delta?(created_at_iso, issue)

      _ ->
        false
    end
  end

  defp comment_accounts_for_delta?(created_at_iso, issue) do
    case DateTime.from_iso8601(created_at_iso) do
      {:ok, comment_time, _} ->
        # GitHub sets issue.updated_at = comment.created_at when a comment lands.
        # If the comment timestamp is >= the stored github_updated_at, the comment
        # is what caused the delta.
        DateTime.compare(comment_time, issue.github_updated_at) in [:gt, :eq]

      _ ->
        false
    end
  end

  # cancel queued/running local pipeline jobs + kill any live session for this
  # issue (used when the cloud lane claims a mid-flight issue)
  defp cancel_local_work(issue) do
    Oban.cancel_all_jobs(
      from(j in Oban.Job,
        where:
          j.worker in [
            "Harness.GitHub.TriageWorker",
            "Harness.GitHub.PlanWorker",
            "Harness.GitHub.ImplementWorker",
            "Harness.GitHub.ReviewWorker"
          ] and
            j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("json_extract(?, '$.issue_id') = ?", j.args, ^issue.id)
      )
    )

    for run <- Harness.Runs.running_runs(), run.issue_id == issue.id do
      Harness.Runs.kill(run.id)
    end
  end

  # open-issues listing no longer contains an issue we track → it closed or
  # was unassigned upstream
  defp reconcile_closed(repo_name, issues) do
    open_numbers = MapSet.new(issues, & &1["number"])

    GitHub.board()
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(fn issue ->
      issue.repo == repo_name and issue.state == "open" and
        issue.pipeline_state not in ["done", "failed", "skipped"] and
        not MapSet.member?(open_numbers, issue.number)
    end)
    |> Enum.each(fn issue ->
      issue
      |> Harness.GitHub.Issue.changeset(%{state: "closed"})
      |> Harness.Repo.update!()
      |> GitHub.transition!("done")
      |> capture_outcome()
    end)
  end

  defp capture_outcome(issue) do
    resolved_at = DateTime.utc_now()
    days_open = DateTime.diff(resolved_at, issue.inserted_at, :second) / 86400.0
    triage = GitHub.latest_triage(issue.id)

    {outcome, amend_commit_count} = classify_outcome(issue)

    GitHub.record_triage_outcome!(%{
      issue_id: issue.id,
      triage_id: triage && triage.id,
      outcome: outcome,
      resolved_at: resolved_at,
      days_open: days_open,
      amend_commit_count: amend_commit_count,
      shadow: false
    })

    :telemetry.execute(
      [:harness, :triage, :outcome_recorded],
      %{count: 1},
      %{outcome: outcome, issue_id: issue.id, repo: issue.repo}
    )

    issue
  end

  defp classify_outcome(%{auto_demoted: true}), do: {"demoted", nil}

  defp classify_outcome(%{pr_number: pr_number, repo: repo} = issue)
       when not is_nil(pr_number) do
    case Client.get_pull_request(repo, pr_number) do
      {:ok, %{merged: true}} ->
        triage = GitHub.latest_triage(issue.id)

        if triage && triage.final_route == "plan" do
          {"plan_executed", nil}
        else
          count_amendments(repo, pr_number)
        end

      {:ok, _} ->
        {"pr_closed_unmerged", nil}

      {:error, reason} ->
        Logger.warning("outcome PR fetch failed for #{repo}##{issue.number}: #{inspect(reason)}")
        {"pr_closed_unmerged", nil}
    end
  end

  defp classify_outcome(_issue), do: {"issue_closed_no_action", nil}

  defp count_amendments(repo, pr_number) do
    case Client.list_pull_request_commits(repo, pr_number) do
      {:ok, commits} ->
        non_harness = max(0, length(commits) - 1)

        if non_harness == 0 do
          {"merged_untouched", 0}
        else
          {"merged_amended", non_harness}
        end

      {:error, _} ->
        {"merged_amended", nil}
    end
  end

  # referenced by moduledoc + tests
  def retriageable_states, do: @retriageable

  @doc false
  def __issue_module__, do: Issue
end
