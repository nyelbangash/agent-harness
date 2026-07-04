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

  alias Harness.GitHub
  alias Harness.GitHub.{Client, Issue}

  # states it is safe to re-triage from when the issue changes upstream
  @retriageable ~w(incoming triaged plan_ready failed skipped done)

  @impl Oban.Worker
  def perform(_job) do
    policy = Harness.Policy.get()

    with {:ok, login} <- assignee_login() do
      for repo <- policy.github.repos do
        poll_repo(repo, login, policy.github.poll_minutes)
      end
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
      case Client.list_assigned_issues(repo.name, login, state.etag) do
        :not_modified ->
          GitHub.update_repo_state!(state, %{last_polled_at: DateTime.utc_now(), last_status: 304})

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

      change == :new ->
        enqueue_triage(issue)

      change == :updated and issue.pipeline_state in @retriageable ->
        enqueue_triage(issue)

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
    end)
  end

  # referenced by moduledoc + tests
  def retriageable_states, do: @retriageable

  @doc false
  def __issue_module__, do: Issue
end
