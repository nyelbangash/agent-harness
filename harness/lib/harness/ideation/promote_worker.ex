defmodule Harness.Ideation.PromoteWorker do
  @moduledoc """
  Promote a synthesized ideation branch to a GitHub issue epic plus child
  issues. Only runs from an explicit human action — never auto-promoted.

  Flow: build context → one model call → create epic → create children →
  patch epic with task list. On child failure, comments on the epic rather
  than deleting already-created children.
  """

  use Oban.Worker,
    queue: :implement,
    max_attempts: 1,
    unique: [keys: [:idea_id, :target_repo], states: :incomplete, period: :infinity]

  require Logger

  alias Harness.GitHub.{Client, Provenance}
  alias Harness.Ideation
  alias Harness.Ideation.Promotion
  alias Harness.Runs.RunSpec
  alias Harness.{Policy, Runs}

  @promote_schema Jason.encode!(%{
                    type: "object",
                    properties: %{
                      epic: %{
                        type: "object",
                        properties: %{
                          title: %{type: "string"},
                          body: %{type: "string"}
                        },
                        required: ["title", "body"],
                        additionalProperties: false
                      },
                      children: %{
                        type: "array",
                        minItems: 1,
                        items: %{
                          type: "object",
                          properties: %{
                            title: %{type: "string"},
                            body: %{type: "string"}
                          },
                          required: ["title", "body"],
                          additionalProperties: false
                        }
                      }
                    },
                    required: ["epic", "children"],
                    additionalProperties: false
                  })

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"session_id" => sid, "idea_id" => iid, "target_repo" => repo}
      }) do
    session = Ideation.get_session!(sid)
    idea = Ideation.get_idea!(iid)
    policy = Policy.get()

    cond do
      policy.mode == :paused ->
        {:cancel, :paused}

      repo not in Enum.map(policy.github.repos, & &1.name) ->
        {:cancel, :repo_not_in_policy}

      true ->
        run_promotion(session, idea, repo, policy)
    end
  end

  defp run_promotion(session, idea, repo, policy) do
    with {:ok, viewer_login} <- resolve_login() do
      ancestors = Ideation.ancestor_chain(idea)
      subtree = Ideation.subtree(idea)
      prompt = Harness.Prompts.promote(session, idea, ancestors, subtree)

      promotion =
        Ideation.create_promotion!(%{
          idea_id: idea.id,
          session_id: session.id,
          target_repo: repo,
          status: "running"
        })

      ref = "ideation:session-#{session.id}/idea-#{idea.id}"

      spec = %RunSpec{
        kind: :promote,
        model: policy.models.plan,
        prompt: prompt,
        cwd: Ideation.session_dir(session),
        output_mode: :json,
        json_schema: @promote_schema,
        allowed_tools: ["Read"],
        max_turns: 15,
        ref: ref,
        timeout_ms: :timer.minutes(10)
      }

      case Runs.execute(spec) do
        {:ok, result} ->
          handle_result(result, promotion, session, idea, repo, viewer_login, ref)

        {:error, :killed} ->
          Ideation.update_promotion!(promotion, %{status: "failed", error_detail: "killed"})
          {:cancel, :killed}

        {:error, reason} ->
          Ideation.update_promotion!(promotion, %{
            status: "failed",
            error_detail: inspect(reason)
          })

          {:error, reason}
      end
    end
  end

  defp handle_result(result, promotion, session, idea, repo, viewer_login, ref) do
    contract = result.structured_output

    if valid_contract?(contract) do
      create_issues(contract, promotion, session, idea, repo, viewer_login, ref, result)
    else
      Ideation.update_promotion!(promotion, %{status: "failed", error_detail: "invalid_contract"})
      {:cancel, :invalid_contract}
    end
  end

  defp valid_contract?(contract) do
    is_map(contract) and
      is_map(contract["epic"]) and
      is_binary(contract["epic"]["title"]) and
      is_binary(contract["epic"]["body"]) and
      is_list(contract["children"]) and
      length(contract["children"]) >= 1 and
      Enum.all?(contract["children"], fn c ->
        is_map(c) and is_binary(c["title"]) and is_binary(c["body"])
      end)
  end

  defp create_issues(contract, promotion, session, _idea, repo, viewer_login, ref, result) do
    epic_body = Provenance.stamp(contract["epic"]["body"], "promote", ref)

    case Client.create_issue(repo, contract["epic"]["title"], epic_body,
           assignees: [viewer_login]
         ) do
      {:ok, %{number: epic_number, url: epic_url}} ->
        Ideation.update_promotion!(promotion, %{
          run_id: result.run_id,
          epic_number: epic_number,
          epic_url: epic_url
        })

        child_links =
          create_children(repo, contract["children"], epic_number, epic_url, viewer_login, ref)

        task_list =
          Enum.map_join(child_links, "\n", fn {_n, url, title} ->
            "- [ ] #{url} — #{title}"
          end)

        new_body = epic_body <> "\n\n## Child issues\n\n#{task_list}"

        case Client.update_issue(repo, epic_number, %{body: new_body}) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("promote: failed to patch epic body: #{inspect(reason)}")
        end

        promotion = Ideation.update_promotion!(promotion, %{status: "succeeded"})

        Phoenix.PubSub.broadcast(
          Harness.PubSub,
          "ideation:#{session.id}",
          {:promotion_completed, promotion}
        )

        Harness.Notify.notify(
          :promotion_complete,
          "Epic created: #{epic_url}"
        )

        :ok

      {:error, reason} ->
        Ideation.update_promotion!(promotion, %{
          status: "failed",
          error_detail: "epic: #{inspect(reason)}"
        })

        {:error, {:epic_creation_failed, reason}}
    end
  end

  defp create_children(repo, children, epic_number, epic_url, viewer_login, ref) do
    total = length(children)

    children
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {child, i}, acc ->
      child_body =
        child["body"] <>
          "\n\n_Part of epic: #{epic_url}_"

      child_body = Provenance.stamp(child_body, "promote", ref)

      case Client.create_issue(repo, child["title"], child_body, assignees: [viewer_login]) do
        {:ok, %{number: n, url: url}} ->
          {:cont, [{n, url, child["title"]} | acc]}

        {:error, reason} ->
          msg = "⚠️ Child creation stopped at ##{i + 1}/#{total}: #{inspect(reason)}"
          Client.post_issue_comment(repo, epic_number, msg)
          {:halt, acc}
      end
    end)
    |> Enum.reverse()
  end

  defp resolve_login do
    case :persistent_term.get({__MODULE__, :login}, nil) do
      nil ->
        case Client.viewer_login() do
          {:ok, login} ->
            :persistent_term.put({__MODULE__, :login}, login)
            {:ok, login}

          {:error, reason} ->
            Logger.warning("promote_worker: could not resolve PAT owner login: #{inspect(reason)}")
            {:error, reason}
        end

      login ->
        {:ok, login}
    end
  end
end
