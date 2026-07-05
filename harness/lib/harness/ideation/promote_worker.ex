defmodule Harness.Ideation.PromoteWorker do
  @moduledoc """
  Promotes a synthesized/high-scoring ideation branch to GitHub issues: one
  epic tracking issue + N child implementation issues. Only runs from an
  explicit operator click — never auto-triggered.

  Contract: {epic: {title, body}, children: [{title, body}]}. If the model
  returns a malformed contract the job fails without touching GitHub. Children
  are created only after the epic succeeds; on child failure the error is
  posted as a comment on the epic rather than deleting already-created issues.
  """

  use Oban.Worker, queue: :ops, max_attempts: 1

  require Logger

  alias Harness.GitHub.{Client, Provenance}
  alias Harness.Ideation
  alias Harness.Runs.RunSpec
  alias Harness.{Policy, Runs}

  @promote_schema Jason.encode!(%{
                    "type" => "object",
                    "properties" => %{
                      "epic" => %{
                        "type" => "object",
                        "properties" => %{
                          "title" => %{"type" => "string"},
                          "body" => %{"type" => "string"}
                        },
                        "required" => ["title", "body"],
                        "additionalProperties" => false
                      },
                      "children" => %{
                        "type" => "array",
                        "items" => %{
                          "type" => "object",
                          "properties" => %{
                            "title" => %{"type" => "string"},
                            "body" => %{"type" => "string"}
                          },
                          "required" => ["title", "body"],
                          "additionalProperties" => false
                        }
                      }
                    },
                    "required" => ["epic", "children"],
                    "additionalProperties" => false
                  })

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "session_id" => session_id,
          "idea_id" => idea_id,
          "target_repo" => target_repo
        }
      }) do
    policy = Policy.get()

    cond do
      policy.mode == :paused ->
        {:cancel, :paused}

      not repo_allowed?(target_repo, policy) ->
        {:cancel, :target_repo_not_in_policy}

      true ->
        session = Ideation.get_session!(session_id)
        idea = Ideation.get_idea!(idea_id)
        promote(session, idea, target_repo, policy)
    end
  end

  defp repo_allowed?(repo, policy) do
    Enum.any?(policy.github.repos, &(&1.name == repo))
  end

  defp promote(session, idea, target_repo, policy) do
    prompt = Harness.Prompts.promote_epic(session, idea)

    spec = %RunSpec{
      kind: :promote,
      model: policy.models.plan,
      prompt: prompt,
      cwd: Ideation.session_dir(session),
      output_mode: :json,
      json_schema: @promote_schema,
      allowed_tools: ~w(Bash Read Glob Grep Write Edit WebSearch WebFetch),
      max_turns: 10,
      ref: "promote-#{session.id}-#{idea.id}"
    }

    case Runs.execute(spec) do
      {:ok,
       %{structured_output: %{"epic" => epic_map, "children" => children_maps}, run_id: run_id}} ->
        create_github_issues(idea, target_repo, epic_map, children_maps, run_id)

      {:ok, _} ->
        Logger.warning(
          "promote session=#{session.id} idea=#{idea.id}: run produced no structured output"
        )

        {:error, :malformed_contract}

      {:error, :killed} ->
        {:cancel, :killed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_github_issues(idea, target_repo, epic_map, children_maps, run_id) do
    case Client.viewer_login() do
      {:ok, login} ->
        epic_body = Provenance.stamp(epic_map["body"], "promote-epic", run_id)

        case Client.create_issue(target_repo, epic_map["title"], epic_body, assignees: [login]) do
          {:ok, epic} ->
            {children, failures} =
              create_children(target_repo, children_maps, epic, run_id, login)

            backfill_epic(target_repo, epic, epic_map["body"], children, run_id)

            for {idx, reason} <- failures do
              comment = "Failed to create child issue #{idx + 1}: #{inspect(reason)}"
              stamped = Provenance.stamp(comment, "promote-fail", run_id)
              _ = Client.post_issue_comment(target_repo, epic.number, stamped)
            end

            Ideation.set_promoted!(idea, epic.number, epic.url)

            Harness.Notify.notify(
              :promote_complete,
              "Promoted to #{target_repo}##{epic.number}: #{epic.url}"
            )

            :ok

          {:error, reason} ->
            {:error, {:epic_creation_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:viewer_login_failed, reason}}
    end
  end

  defp create_children(target_repo, children_maps, epic, run_id, login) do
    children_maps
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {child_map, idx}, {successes, failures} ->
      body_raw = child_map["body"] <> "\n\nPart of epic: #{epic.url}"
      body = Provenance.stamp(body_raw, "promote-child", run_id)

      case Client.create_issue(target_repo, child_map["title"], body, assignees: [login]) do
        {:ok, result} -> {successes ++ [result], failures}
        {:error, reason} -> {successes, failures ++ [{idx, reason}]}
      end
    end)
  end

  defp backfill_epic(target_repo, epic, original_body, children, run_id) do
    task_list =
      children
      |> Enum.map(fn %{number: n, url: url} -> "- [ ] #{url} (##{n})" end)
      |> Enum.join("\n")

    updated_body = original_body <> "\n\n## Issues\n\n" <> task_list
    updated_body_stamped = Provenance.stamp(updated_body, "promote-epic", run_id)
    _ = Client.edit_issue(target_repo, epic.number, %{body: updated_body_stamped})
    :ok
  end
end
