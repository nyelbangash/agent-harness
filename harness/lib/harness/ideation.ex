defmodule Harness.Ideation do
  @moduledoc """
  Ideation context (spec §5). The idea tree is the memory; each iteration is
  a fresh headless session (Ralph-style, no conversation carryover). This
  module owns the tree structure, the frontier-selection heuristic that makes
  the tree *compound* rather than tunnel, and the on-disk artifact/journal
  layout under `~/.harness/ideation/{session}/`.

  Broadcasts on `"ideation"` (session list) and `"ideation:{id}"` (one tree).
  """

  import Ecto.Query

  require Logger

  alias Harness.Ideation.{Idea, Session}
  alias Harness.Repo

  # -- pubsub -----------------------------------------------------------------

  def subscribe, do: Phoenix.PubSub.subscribe(Harness.PubSub, "ideation")

  def subscribe(session_id),
    do: Phoenix.PubSub.subscribe(Harness.PubSub, "ideation:#{session_id}")

  defp broadcast(session_id, message) do
    Phoenix.PubSub.broadcast(Harness.PubSub, "ideation", message)
    Phoenix.PubSub.broadcast(Harness.PubSub, "ideation:#{session_id}", message)
  end

  # -- sessions ---------------------------------------------------------------

  @doc "Create a session, seed its root idea, and enqueue the first iteration."
  def start_session(attrs) do
    session =
      %Session{}
      |> Session.changeset(Map.put(attrs, :started_at, DateTime.utc_now()))
      |> Repo.insert!()

    File.mkdir_p!(session_dir(session))
    write_journal_header(session)
    attach_seed_repos!(session)

    root =
      %Idea{}
      |> Idea.changeset(%{
        session_id: session.id,
        depth: 0,
        title: "Seed",
        summary: String.slice(session.seed_prompt, 0, 200),
        status: "frontier",
        score: 8.0
      })
      |> Repo.insert!()

    broadcast(session.id, {:session_started, session})
    enqueue_iteration(session)
    {session, root}
  end

  def get_session!(id), do: Repo.get!(Session, id)

  def list_sessions do
    from(s in Session, order_by: [desc: s.id]) |> Repo.all()
  end

  def running_sessions do
    from(s in Session, where: s.status == "running") |> Repo.all()
  end

  def update_session!(%Session{} = session, attrs) do
    session = session |> Session.changeset(attrs) |> Repo.update!()
    broadcast(session.id, {:session_updated, session})
    session
  end

  @doc """
  Stop a session (operator or a stop condition), recording the reason and
  enqueuing the final synthesis (spec §5.2: "On stop, a final Opus synthesis
  writes SYNTHESIS.md"). Idempotent — a session already past running is left
  alone so this can't double-enqueue.
  """
  def stop_session!(%Session{status: "running"} = session, reason) do
    session =
      update_session!(session, %{
        status: "stopped",
        stop_reason: to_string(reason),
        ended_at: DateTime.utc_now()
      })

    %{session_id: session.id, final: true}
    |> Harness.Ideation.CritiqueWorker.new()
    |> Oban.insert()

    session
  end

  def stop_session!(%Session{} = session, _reason), do: session

  # -- ideas / tree -----------------------------------------------------------

  def tree(session_id) do
    from(i in Idea, where: i.session_id == ^session_id, order_by: [asc: i.id]) |> Repo.all()
  end

  def get_idea!(id), do: Repo.get!(Idea, id)

  @doc "Persist a child idea with its markdown artifact."
  def add_child!(session, parent, attrs, artifact_body) do
    node_index = Repo.aggregate(from(i in Idea, where: i.session_id == ^session.id), :count) + 1
    artifact_path = Path.join(session_dir(session), "node-#{node_index}.md")
    File.write!(artifact_path, artifact_body)

    %Idea{}
    |> Idea.changeset(
      Map.merge(attrs, %{
        session_id: session.id,
        parent_id: parent.id,
        depth: parent.depth + 1,
        status: "frontier",
        artifact_path: artifact_path
      })
    )
    |> Repo.insert!()
  end

  @doc "Mark a node expanded (it has produced children / been developed)."
  def mark_expanded!(%Idea{} = idea), do: set_status!(idea, "expanded")
  def mark_pruned!(%Idea{} = idea), do: set_status!(idea, "pruned")

  def set_score!(%Idea{} = idea, score) do
    idea |> Idea.changeset(%{score: score}) |> Repo.update!()
  end

  defp set_status!(idea, status) do
    idea |> Idea.changeset(%{status: status}) |> Repo.update!()
  end

  # -- frontier selection (the compounding heuristic) -------------------------

  @doc """
  Pick the next node to work: highest `score × novelty_decay(depth)` among
  un-expanded, un-pruned nodes. The depth decay is what stops the tree from
  tunnelling down one deep branch — shallower high-scorers stay competitive,
  so exploration keeps branching. Returns nil when the frontier is empty.
  """
  def select_frontier(session_id, opts \\ []) do
    decay = Keyword.get(opts, :decay, 0.85)

    from(i in Idea,
      where: i.session_id == ^session_id and i.status == "frontier"
    )
    |> Repo.all()
    |> Enum.max_by(&priority(&1, decay), fn -> nil end)
  end

  @doc false
  def priority(%Idea{} = idea, decay), do: idea.score * :math.pow(decay, idea.depth)

  @doc "Ancestor chain root→node (context for the iteration prompt)."
  def ancestor_chain(%Idea{} = idea) do
    Stream.unfold(idea, fn
      nil -> nil
      %Idea{parent_id: nil} = n -> {n, nil}
      %Idea{parent_id: pid} = n -> {n, Repo.get(Idea, pid)}
    end)
    |> Enum.reverse()
  end

  @doc "One-line summaries of a node's siblings (breadth context)."
  def sibling_summaries(%Idea{parent_id: nil}), do: []

  def sibling_summaries(%Idea{parent_id: pid, id: id}) do
    from(i in Idea, where: i.parent_id == ^pid and i.id != ^id, select: {i.title, i.score})
    |> Repo.all()
    |> Enum.map(fn {title, score} -> "#{title} (score #{score})" end)
  end

  def frontier_count(session_id) do
    Repo.aggregate(
      from(i in Idea, where: i.session_id == ^session_id and i.status == "frontier"),
      :count
    )
  end

  # -- artifacts / journal ----------------------------------------------------

  def session_dir(%Session{id: id}) do
    Path.join([Application.fetch_env!(:harness, :harness_home), "ideation", "session-#{id}"])
  end

  def journal_path(session), do: Path.join(session_dir(session), "JOURNAL.md")
  def synthesis_path(session), do: Path.join(session_dir(session), "SYNTHESIS.md")

  def read_journal(session) do
    case File.read(journal_path(session)) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  @doc "Append a capped 3-line entry (§5.2 keeps the journal from bloating)."
  def append_journal!(session, iteration, lines) do
    entry =
      lines
      |> List.wrap()
      |> Enum.take(3)
      |> Enum.map_join("\n", &("- " <> String.slice(&1, 0, 200)))

    File.write!(
      journal_path(session),
      "\n## Iteration #{iteration}\n#{entry}\n",
      [:append]
    )
  end

  defp write_journal_header(session) do
    File.write!(journal_path(session), """
    # Ideation journal — session #{session.id}

    Seed: #{session.seed_prompt}
    Started: #{session.started_at}
    """)
  end

  def read_artifact(%Idea{artifact_path: nil}), do: nil

  def read_artifact(%Idea{artifact_path: path}) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  # -- repo grounding ---------------------------------------------------------

  @doc """
  Scans `text` for mentions of repos from `policy_repos` (full "owner/name"
  or bare repo name as a word). Returns `{matched_names, skipped_patterns}`
  where matched_names are in the policy and skipped_patterns look like repo
  refs but are not in the policy list.
  """
  def detect_referenced_repos(text, policy_repos) when is_list(policy_repos) do
    policy_names = Enum.map(policy_repos, & &1.name)

    # Extract all owner/name-like tokens from text
    candidates =
      ~r/\b([\w.-]+\/[\w.-]+)\b/
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    full_matches = MapSet.new(Enum.filter(candidates, &(&1 in policy_names)))
    skipped = Enum.reject(candidates, &(&1 in policy_names))

    # Bare name matches: policy repos not yet matched by full name
    bare_matches =
      policy_repos
      |> Enum.reject(&MapSet.member?(full_matches, &1.name))
      |> Enum.filter(fn repo ->
        bare = repo.name |> String.split("/") |> List.last()
        String.match?(text, ~r/(?<![\/\w])#{Regex.escape(bare)}(?![\/\w])/)
      end)
      |> Enum.map(& &1.name)

    matched = MapSet.to_list(full_matches) ++ bare_matches
    {matched, skipped}
  end

  @doc """
  Returns `[{repo_name, checkout_path}]` for policy repos referenced in the
  session's seed prompt. Calls `Repos.ensure_base!/1` for each matched repo
  (idempotent — safe to call at every iteration).
  """
  def grounding_repos(%Session{} = session) do
    policy = Harness.Policy.get()
    {matched, _skipped} = detect_referenced_repos(session.seed_prompt, policy.github.repos)

    Enum.map(matched, fn repo_name ->
      path = Harness.Repos.ensure_base!(repo_name)
      {repo_name, path}
    end)
  end

  # Detects, provisions, and journals repos referenced in the seed at session
  # start. Skipped (non-policy) refs are journal-logged as an access-boundary
  # audit trail; matched repos get their base clones ensured.
  defp attach_seed_repos!(session) do
    policy = Harness.Policy.get()
    {matched, skipped} = detect_referenced_repos(session.seed_prompt, policy.github.repos)

    repos =
      Enum.map(matched, fn repo_name ->
        path = Harness.Repos.ensure_base!(repo_name)
        {repo_name, path}
      end)

    journal_lines =
      Enum.map(skipped, &"referenced repo not in policy — skipped: #{&1}") ++
        if repos != [],
          do: ["Grounding repos attached: #{Enum.map_join(repos, ", ", fn {n, _} -> n end)}"],
          else: []

    if journal_lines != [], do: append_journal!(session, 0, journal_lines)

    repos
  end

  # -- job orchestration ------------------------------------------------------

  @doc "Enqueue the next iteration for a still-running session."
  def enqueue_iteration(%Session{status: "running", id: id}) do
    %{session_id: id} |> Harness.Ideation.IterationWorker.new() |> Oban.insert()
  end

  def enqueue_iteration(_session), do: :noop
end
