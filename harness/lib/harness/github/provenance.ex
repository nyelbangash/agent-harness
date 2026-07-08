defmodule Harness.GitHub.Provenance do
  @moduledoc """
  Convention: every harness-authored GitHub body must pass through stamp/3;
  readers must filter with harness_authored?/1 before treating owner-authored
  text as instructions.

  Self-acknowledge rule: any code path that posts a GitHub comment via
  Client.post_issue_comment/3 MUST immediately advance the stored
  issues.github_updated_at to the comment's created_at AND record the
  comment's id (via GitHub.acknowledge_comment_timestamp!/3). This prevents
  PollWorker from treating the harness's own comment as operator activity and
  re-triaging the issue. `harness_caused_update?/1` keys off the stored
  comment id, not the timestamp — the issues-list and comments-list GitHub
  API surfaces don't reliably agree on time for the same event (issue #99),
  so identity is the only reliable signal.

  The marker is an HTML comment (`<!-- harness:v1 kind=… ref=… -->`), which
  GitHub renders as invisible in issue comments and PR bodies.
  """

  @marker_re ~r/<!-- harness:v1 kind=(?<kind>[^\s>]+) ref=(?<ref>[^\s>]+) -->/

  @doc "Appends a provenance marker to body. Both kind and ref must be whitespace-free strings."
  def stamp(body, kind, ref) do
    String.trim_trailing(body) <> "\n<!-- harness:v1 kind=#{kind} ref=#{ref} -->"
  end

  @doc "Returns true iff body carries a harness provenance marker."
  def harness_authored?(body), do: body =~ @marker_re

  @doc "Parses the provenance marker from body. Returns `{:ok, map}` or `:error`."
  def parse(body) do
    case Regex.named_captures(@marker_re, body) do
      %{"kind" => kind, "ref" => ref} -> {:ok, %{version: "v1", kind: kind, ref: ref}}
      nil -> :error
    end
  end
end
