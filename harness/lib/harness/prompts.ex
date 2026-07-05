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

  def plan(issue, comments, triage, default_branch, failure_transcript \\ nil, plan_max_turns \\ nil) do
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
      failure_transcript: failure_transcript,
      plan_max_turns: plan_max_turns
    )
  end

  def review(issue, comments, base_branch) do
    render("review.md.eex",
      repo: issue.repo,
      issue_number: issue.number,
      issue_title: truncate(issue.title, 500),
      issue_body: truncate(issue.body || "(no body)", @max_body_chars),
      comments: prepare_comments(comments),
      base_branch: base_branch
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

  # -- ideation ---------------------------------------------------------------

  alias Harness.Ideation

  def ideate(mode, session, node, grounding_repos \\ []) do
    template = if mode == :diverge, do: "ideate_diverge.md.eex", else: "ideate_develop.md.eex"

    render(template,
      # seed is trusted operator input, included verbatim (anti-drift §5.2)
      seed_prompt: session.seed_prompt,
      node_title: node.title,
      node_depth: node.depth,
      node_score: node.score,
      node_summary: node.summary || "",
      ancestor_chain: format_ancestors(node),
      sibling_summaries: format_siblings(node),
      journal: truncate(Ideation.read_journal(session), 8_000),
      grounding_repos: grounding_repos
    )
  end

  def critique(session, grounding_repos \\ []) do
    render("critique.md.eex",
      seed_prompt: session.seed_prompt,
      frontier: format_frontier(session),
      journal: truncate(Ideation.read_journal(session), 10_000),
      grounding_repos: grounding_repos
    )
  end

  def synthesis(session) do
    render("synthesis.md.eex",
      seed_prompt: session.seed_prompt,
      tree_outline: format_tree(session)
    )
  end

  defp format_ancestors(node) do
    node
    |> Ideation.ancestor_chain()
    |> Enum.map_join("\n", fn n ->
      "#{String.duplicate("  ", n.depth)}- #{n.title}: #{n.summary}"
    end)
  end

  defp format_siblings(node) do
    case Ideation.sibling_summaries(node) do
      [] -> "(none)"
      sums -> Enum.join(sums, "\n")
    end
  end

  defp format_frontier(session) do
    session.id
    |> Ideation.tree()
    |> Enum.filter(&(&1.status == "frontier"))
    |> Enum.map_join("\n", fn i -> "#{i.id} · #{i.title} · score #{i.score}" end)
  end

  defp format_tree(session) do
    session.id
    |> Ideation.tree()
    |> Enum.map_join("\n", fn i ->
      "#{i.id} · d#{i.depth} · #{i.status} · #{i.score} · #{i.title}"
    end)
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
