defmodule Harness.Compose.ExploreWorker do
  @moduledoc """
  Runs a read-only exploration session in the target repo's worktree,
  then persists the resulting DRAFT.json into the issue_drafts table.
  Queue :compose (concurrency 1) — operator-paced; no issue FK.
  """

  use Oban.Worker,
    queue: :compose,
    max_attempts: 2,
    unique: [keys: [:draft_id], states: :incomplete, period: :infinity]

  require Logger

  alias Harness.Compose
  alias Harness.Runs.RunSpec
  alias Harness.{Policy, Repos, Runs}

  @explore_tools ~w(Bash Read Glob Grep Write Edit WebSearch WebFetch)

  @min_draft_bytes 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"draft_id" => draft_id}}) do
    draft = Compose.get_draft!(draft_id)

    case Policy.gate(:compose) do
      :ok -> explore(draft)
      {:snooze, seconds, _reason} -> {:snooze, seconds}
      {:skip, reason} -> {:cancel, reason}
    end
  end

  defp explore(draft) do
    policy = Policy.get()
    Repos.ensure_base!(draft.repo)

    worktree =
      Repos.create_worktree!(
        draft.repo,
        "compose-draft-#{draft.id}-#{System.unique_integer([:positive])}"
      )

    try do
      repo_map = Repos.repo_map(draft.repo)

      prompt =
        Harness.Prompts.explore(
          draft.prompt,
          repo_map,
          policy.budgets.compose_max_turns,
          Compose.attachments(draft)
        )

      spec = %RunSpec{
        kind: :explore,
        model: policy.models.plan,
        prompt: prompt,
        cwd: worktree,
        worktree: worktree,
        output_mode: :stream_json,
        allowed_tools: @explore_tools,
        max_turns: policy.budgets.compose_max_turns,
        ref: "compose/draft-#{draft.id}"
      }

      case Runs.execute(spec) do
        {:ok, result} ->
          persist_draft(draft, worktree, result.run_id)

        {:error, :killed} ->
          {:cancel, :killed}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Repos.remove_worktree!(draft.repo, worktree)
    end
  end

  defp persist_draft(draft, worktree, run_id) do
    json_path = Path.join(worktree, "DRAFT.json")

    with {:ok, stat} <- File.stat(json_path),
         true <- stat.size >= @min_draft_bytes,
         {:ok, raw} <- File.read(json_path),
         {:ok, parsed} <- Jason.decode(raw) do
      Compose.update_draft!(draft, %{
        run_id: run_id,
        title: parsed["title"],
        body: parsed["body"],
        scope_hint: parsed["scope_hint"],
        open_questions: Jason.encode!(List.wrap(parsed["open_questions"]))
      })

      :ok
    else
      _ ->
        Logger.warning("explore run for draft #{draft.id} left no usable DRAFT.json")
        {:error, :missing_draft_artifact}
    end
  end
end
