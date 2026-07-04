defmodule Harness.Prompts do
  @moduledoc """
  Renders the versioned prompt templates in `ops/prompts/` (EEx). Untrusted
  issue content is truncated here so a hostile 65k-char issue body can't
  blow the prompt (passed via argv) past sane limits.
  """

  @max_body_chars 30_000
  @max_comment_chars 4_000
  @max_comments 20

  def triage(issue, comments, repo_map) do
    render("triage.md.eex",
      repo: issue.repo,
      issue_number: issue.number,
      issue_title: truncate(issue.title, 500),
      issue_author: issue.author || "unknown",
      issue_labels: issue.labels,
      issue_body: truncate(issue.body || "(no body)", @max_body_chars),
      comments: prepare_comments(comments),
      repo_map: truncate(repo_map, 20_000)
    )
  end

  def plan(issue, comments, triage, default_branch, failure_transcript \\ nil) do
    render("plan.md.eex",
      repo: issue.repo,
      issue_number: issue.number,
      issue_title: truncate(issue.title, 500),
      issue_labels: issue.labels,
      issue_body: truncate(issue.body || "(no body)", @max_body_chars),
      comments: prepare_comments(comments),
      default_branch: default_branch,
      estimated_scope: (triage && triage.estimated_scope) || "unknown",
      risk_flags: (triage && triage.risk_flags) || [],
      triage_reasoning: truncate((triage && triage.reasoning) || "(no triage reasoning)", 2_000),
      failure_transcript: failure_transcript
    )
  end

  def implement(issue, comments, plan_text, repo_cfg) do
    render("implement.md.eex",
      repo: issue.repo,
      issue_number: issue.number,
      issue_title: truncate(issue.title, 500),
      issue_labels: issue.labels,
      issue_body: truncate(issue.body || "(no body)", @max_body_chars),
      comments: prepare_comments(comments),
      plan: plan_text && truncate(plan_text, 20_000),
      test_command: repo_cfg.test_command
    )
  end

  defp render(template, assigns) do
    Application.fetch_env!(:harness, :prompts_dir)
    |> Path.join(template)
    |> EEx.eval_file(assigns: assigns)
  end

  defp prepare_comments(comments) do
    comments
    |> Enum.take(@max_comments)
    |> Enum.map(fn comment ->
      %{
        author: get_in(comment, ["user", "login"]) || "unknown",
        created_at: comment["created_at"] || "",
        body: truncate(comment["body"] || "", @max_comment_chars)
      }
    end)
  end

  defp truncate(nil, _limit), do: ""

  defp truncate(text, limit) do
    text = sanitize(text)

    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "\n… (truncated)"
    else
      text
    end
  end

  # untrusted content must not be able to forge the trust-boundary markers
  # the templates wrap it in (e.g. a premature <<<END-ISSUE-DATA>>> followed
  # by a fake "trusted" section)
  defp sanitize(text) do
    text
    |> String.replace("<<<", "‹‹‹")
    |> String.replace(">>>", "›››")
  end
end
