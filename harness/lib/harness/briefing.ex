defmodule Harness.Briefing do
  @moduledoc """
  Daily morning briefing: assembles a deterministic memo from overnight
  activity, persists it to the `briefings` table (one row per day, idempotent
  on retry), and delivers a one-line summary via `Harness.Notify`.

  `OverviewLive` renders the latest undismissed briefing as a full-width card.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Harness.GitHub.{Issue, Plan, TriageDecision}
  alias Harness.Ideation.{Idea, Session}
  alias Harness.Runs.Run
  alias Harness.{Repo, Runs, Usage}

  @topic "briefings"

  schema "briefings" do
    field :date, :date
    field :markdown, :string
    field :dismissed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(briefing, attrs) do
    briefing
    |> cast(attrs, [:date, :markdown, :dismissed_at])
    |> validate_required([:date, :markdown])
    |> unique_constraint(:date)
  end

  # -- public API ----------------------------------------------------------------

  @doc "Latest briefing where dismissed_at IS NULL, or nil."
  def latest_undismissed do
    from(b in __MODULE__,
      where: is_nil(b.dismissed_at),
      order_by: [desc: b.date],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Most recent briefing regardless of dismissed state, or nil."
  def latest_any do
    from(b in __MODULE__, order_by: [desc: b.date], limit: 1)
    |> Repo.one()
  end

  @doc "Set dismissed_at to now and return the updated struct."
  def dismiss!(%__MODULE__{} = briefing) do
    briefing
    |> changeset(%{dismissed_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  @doc "Insert or replace the briefing for `date`. Broadcasts after upsert."
  def upsert!(date, markdown) do
    briefing =
      %__MODULE__{}
      |> changeset(%{date: date, markdown: markdown})
      |> Repo.insert!(
        on_conflict: [set: [markdown: markdown, updated_at: DateTime.utc_now()]],
        conflict_target: :date
      )

    broadcast({:briefing_updated, briefing})
    briefing
  end

  @doc "Subscribe to PubSub briefing events."
  def subscribe, do: Phoenix.PubSub.subscribe(Harness.PubSub, @topic)

  @doc """
  Query all sections for the window `since..now`. Returns `{markdown, one_liner}`.
  Pure DB reads — no model call.
  """
  def assemble(since) do
    prs = query_prs(since)
    plans = query_ready_plans(since)
    triages = query_triage_counts(since)
    ideation = query_ideation(since)
    budget = query_budget()
    failures = query_failures(since)

    markdown = render_markdown(prs, plans, triages, ideation, budget, failures)
    one_liner = render_one_liner(prs, plans, failures)

    {markdown, one_liner}
  end

  # -- private query helpers ---------------------------------------------------

  defp query_prs(since) do
    from(i in Issue,
      where:
        i.pipeline_state == "pr_open" and
          not is_nil(i.pr_url) and
          i.updated_at >= ^since,
      select: %{repo: i.repo, number: i.number, title: i.title, pr_url: i.pr_url}
    )
    |> Repo.all()
  end

  defp query_ready_plans(since) do
    from(p in Plan,
      join: i in Issue,
      on: i.id == p.issue_id,
      where: p.status == "ready" and p.inserted_at >= ^since,
      select: %{
        issue_title: i.title,
        issue_repo: i.repo,
        issue_number: i.number,
        summary: p.summary,
        branch: p.branch
      }
    )
    |> Repo.all()
  end

  defp query_triage_counts(since) do
    from(t in TriageDecision,
      where: t.inserted_at >= ^since,
      group_by: t.final_route,
      select: {t.final_route, count(t.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp query_ideation(since) do
    sessions =
      from(s in Session,
        where: not is_nil(s.ended_at) and s.ended_at >= ^since,
        select: %{synthesis: not is_nil(s.synthesis_path)}
      )
      |> Repo.all()

    runs_by_kind =
      from(r in Run,
        where: r.kind in ["ideate", "critique"] and r.inserted_at >= ^since,
        group_by: r.kind,
        select: {r.kind, count(r.id)}
      )
      |> Repo.all()
      |> Map.new()

    top_ideas =
      from(idea in Idea,
        where: idea.inserted_at >= ^since,
        order_by: [desc: idea.score],
        limit: 5,
        select: %{title: idea.title, score: idea.score}
      )
      |> Repo.all()

    sessions_count = length(sessions)
    synthesis_count = Enum.count(sessions, & &1.synthesis)

    %{
      sessions_count: sessions_count,
      synthesis_count: synthesis_count,
      runs_by_kind: runs_by_kind,
      top_ideas: top_ideas
    }
  end

  defp query_budget do
    policy = Harness.Policy.get()
    oauth = Usage.latest_samples()["oauth_api"]

    %{
      five_hour_util: oauth && oauth.five_hour_utilization,
      seven_day_util: oauth && oauth.seven_day_utilization,
      opus_hours: Runs.opus_hours_this_week(),
      opus_cap: policy.budgets.opus_hours_weekly_cap,
      overflow: Runs.overflow_usd_this_week() || 0.0,
      overflow_cap: policy.budgets.overflow_usd_weekly_cap,
      stale: Usage.health() == :stale
    }
  end

  defp query_failures(since) do
    runs =
      from(r in Run,
        where: r.status in ["failed", "killed"] and r.inserted_at >= ^since,
        select: %{id: r.id, kind: r.kind, ref: r.ref, error: r.error}
      )
      |> Repo.all()

    %{runs: runs, stale: Usage.health() == :stale}
  end

  # -- render helpers ----------------------------------------------------------

  defp render_markdown(prs, plans, triages, ideation, budget, failures) do
    quiet? =
      prs == [] and
        plans == [] and
        map_size(triages) == 0 and
        ideation.sessions_count == 0 and
        map_size(ideation.runs_by_kind) == 0 and
        ideation.top_ideas == [] and
        failures.runs == []

    if quiet? do
      "Quiet night — no activity during this period."
    else
      [
        prs_section(prs),
        plans_section(plans),
        triage_section(triages),
        ideation_section(ideation),
        budget_section(budget),
        failures_section(failures)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
    end
  end

  defp prs_section([]), do: nil

  defp prs_section(prs) do
    items =
      Enum.map(prs, fn pr ->
        "- [#{pr.repo}##{pr.number}: #{pr.title}](#{pr.pr_url})"
      end)

    "## PRs Opened\n\n#{Enum.join(items, "\n")}"
  end

  defp plans_section([]), do: nil

  defp plans_section(plans) do
    items =
      Enum.map(plans, fn p ->
        summary = if p.summary, do: " — #{String.slice(p.summary, 0, 120)}", else: ""
        "- #{p.issue_repo}##{p.issue_number}: #{p.issue_title}#{summary}"
      end)

    "## Plans Ready\n\n#{Enum.join(items, "\n")}"
  end

  defp triage_section(triages) when map_size(triages) == 0, do: nil

  defp triage_section(triages) do
    total = Map.values(triages) |> Enum.sum()

    lines =
      triages
      |> Enum.sort_by(fn {route, _} -> route end)
      |> Enum.map(fn {route, n} -> "- #{route}: #{n}" end)

    "## Triage Activity (#{total} total)\n\n#{Enum.join(lines, "\n")}"
  end

  defp ideation_section(%{sessions_count: 0, runs_by_kind: r, top_ideas: []})
       when map_size(r) == 0,
       do: nil

  defp ideation_section(ideation) do
    lines = []

    lines =
      if ideation.sessions_count > 0 do
        synth =
          if ideation.synthesis_count > 0,
            do: " (#{ideation.synthesis_count} with synthesis)",
            else: ""

        ["- Sessions ended: #{ideation.sessions_count}#{synth}" | lines]
      else
        lines
      end

    lines =
      ideation.runs_by_kind
      |> Enum.sort_by(fn {kind, _} -> kind end)
      |> Enum.reduce(lines, fn {kind, n}, acc ->
        ["- #{String.capitalize(kind)} runs: #{n}" | acc]
      end)

    lines =
      if ideation.top_ideas != [] do
        idea_lines =
          Enum.map(ideation.top_ideas, fn idea ->
            score = :erlang.float_to_binary(idea.score / 1, decimals: 1)
            "  - #{idea.title} (#{score})"
          end)

        ["- Top ideas:\n#{Enum.join(idea_lines, "\n")}" | lines]
      else
        lines
      end

    body = lines |> Enum.reverse() |> Enum.join("\n")
    "## Ideation\n\n#{body}"
  end

  defp budget_section(budget) do
    opus_pct =
      if budget.opus_cap > 0, do: round(budget.opus_hours / budget.opus_cap * 100), else: 0

    overflow_pct =
      if budget.overflow_cap > 0, do: round(budget.overflow / budget.overflow_cap * 100), else: 0

    lines = [
      maybe_util_line("5-hr utilization", budget.five_hour_util, budget.stale),
      maybe_util_line("7-day utilization", budget.seven_day_util, budget.stale),
      "- Opus hours: #{:erlang.float_to_binary(budget.opus_hours / 1, decimals: 1)}h / #{round(budget.opus_cap)}h cap (#{opus_pct}%)",
      "- Overflow spend: $#{:erlang.float_to_binary(budget.overflow / 1, decimals: 2)} / $#{round(budget.overflow_cap)} cap (#{overflow_pct}%)"
    ]

    body = lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
    "## Budget Position\n\n#{body}"
  end

  defp maybe_util_line(_label, nil, _stale), do: nil

  defp maybe_util_line(label, value, stale) do
    stale_note = if stale, do: " ⚠ stale", else: ""
    "- #{label}: #{round(value)}%#{stale_note}"
  end

  defp failures_section(%{runs: [], stale: false}), do: nil

  defp failures_section(failures) do
    lines = []

    lines =
      if failures.stale do
        ["- **Usage telemetry stale** — fail-closed to plan-only" | lines]
      else
        lines
      end

    lines =
      Enum.reduce(failures.runs, lines, fn run, acc ->
        ref = if run.ref, do: " #{run.ref}", else: ""
        error = if run.error, do: " — #{String.slice(run.error, 0, 100)}", else: ""
        ["- ##{run.id} #{run.kind}#{ref}#{error}" | acc]
      end)

    body = lines |> Enum.reverse() |> Enum.join("\n")
    "## Failures\n\n#{body}"
  end

  defp render_one_liner(prs, plans, failures) do
    parts =
      [
        {length(prs), "PR", "PRs"},
        {length(plans), "plan ready", "plans ready"},
        {length(failures.runs), "failure", "failures"}
      ]
      |> Enum.reject(fn {n, _, _} -> n == 0 end)
      |> Enum.map(fn {n, sing, pl} -> "#{n} #{if n == 1, do: sing, else: pl}" end)

    if parts == [], do: "Quiet night", else: Enum.join(parts, " · ")
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Harness.PubSub, @topic, message)
  end
end
