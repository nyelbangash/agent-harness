defmodule Harness.GitHub.ProjectPollWorker do
  @moduledoc """
  Issue discovery from GitHub Projects (v2) boards (issue #96), alongside
  `PollWorker`'s per-repo assignee polling. Cron fires every minute; the
  worker early-exits per board unless `github.poll_minutes` has elapsed
  (same self-throttling shape as `PollWorker`).

  Projects v2 has no REST surface — `Client.list_project_items/2` is
  GraphQL-only. Matching `Issue` items are upserted through
  `PollWorker.handle_issue/2`, the exact path assignee-discovered issues use,
  so triage/plan/implement routing and idempotency guards are identical.
  `PullRequest` items are ignored (the pipeline is issue-driven).
  `DraftIssue` items are skipped with a logged notice — they belong to no
  repo, so there is no branch target.
  """

  use Oban.Worker, queue: :ops, max_attempts: 1, unique: [period: 55]

  require Logger

  alias Harness.GitHub
  alias Harness.GitHub.{Client, PollWorker}

  @impl Oban.Worker
  def perform(_job) do
    policy = Harness.Policy.get()

    for project <- policy.github.projects do
      poll_project(project, policy)
    end

    :ok
  end

  defp poll_project(project, policy) do
    state = GitHub.project_state(project.owner, project.number)

    if due?(state, policy.github.poll_minutes) do
      case Client.list_project_items(project.owner, project.number) do
        {:ok, items} ->
          Enum.each(items, &handle_item(project, policy, &1))

          GitHub.update_project_state!(state, %{
            last_polled_at: DateTime.utc_now(),
            last_status: "ok"
          })

        {:error, reason} ->
          Logger.warning(
            "project poll #{project.owner}/#{project.number} failed: #{inspect(reason)}"
          )

          GitHub.update_project_state!(state, %{
            last_polled_at: DateTime.utc_now(),
            last_status: "error"
          })
      end
    end
  end

  defp due?(%{last_polled_at: nil}, _minutes), do: true

  defp due?(%{last_polled_at: last}, minutes) do
    DateTime.diff(DateTime.utc_now(), last, :second) >= minutes * 60 - 5
  end

  defp handle_item(project, policy, %{type: :issue} = item) do
    if matches_trigger?(project, item) do
      PollWorker.handle_issue(item.repo, to_rest_payload(item))
      unless repo_configured?(policy, item.repo), do: maybe_log_plan_only(item.repo)
    end
  end

  defp handle_item(_project, _policy, %{type: :pull_request}), do: :ok

  defp handle_item(project, _policy, %{type: :draft_issue} = item) do
    Logger.warning(
      "project #{project.owner}/#{project.number}: skipping draft issue #{inspect(item.title)} — no repo, no branch target"
    )
  end

  defp handle_item(_project, _policy, %{type: :unknown}), do: :ok

  defp matches_trigger?(project, item) do
    case project.trigger do
      :assignee ->
        case assignee_login(project.owner) do
          {:ok, login} -> login in item.assignees
          {:error, _reason} -> false
        end

      {:field, name, value} ->
        Enum.any?(item.field_values, &(&1.field == name and &1.value == value))
    end
  end

  defp assignee_login(owner) do
    case :persistent_term.get({__MODULE__, :login, owner}, nil) do
      nil ->
        case Client.viewer_login(owner) do
          {:ok, login} ->
            :persistent_term.put({__MODULE__, :login, owner}, login)
            {:ok, login}

          {:error, reason} ->
            Logger.warning("could not resolve PAT owner login for #{owner}: #{inspect(reason)}")
            {:error, reason}
        end

      login ->
        {:ok, login}
    end
  end

  defp repo_configured?(policy, repo_name) do
    Enum.any?(policy.github.repos, &(&1.name == repo_name))
  end

  # once-per-repo notice: a project issue in a repo absent from
  # policy.github.repos can still be triaged/planned, but the auto lane
  # requires a test_command, which only comes from a github.repos entry —
  # so it is plan-lane only. Logged once per process, not time-windowed.
  defp maybe_log_plan_only(repo_name) do
    key = {__MODULE__, :logged_plan_only, repo_name}

    unless :persistent_term.get(key, false) do
      Logger.warning(
        "project issue in #{repo_name} has no policy.github.repos entry — plan-lane only (no test_command)"
      )

      :persistent_term.put(key, true)
    end
  end

  defp to_rest_payload(item) do
    %{
      "id" => item.github_id,
      "number" => item.number,
      "title" => item.title,
      "body" => item.body,
      "state" => item.state && String.downcase(item.state),
      "labels" => Enum.map(item.labels, &%{"name" => &1}),
      "user" => %{"login" => item.author},
      "html_url" => item.url,
      "comments" => item.comments_count,
      "updated_at" => item.updated_at
    }
  end
end
