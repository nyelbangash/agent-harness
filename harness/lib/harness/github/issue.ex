defmodule Harness.GitHub.Issue do
  @moduledoc """
  A GitHub issue mirrored locally, plus its position in the pipeline.

  `pipeline_state` is ours (GitHub's open/closed lives in `state`):

      incoming → triaging → triaged → planning → plan_ready
                                    ↘ (Phase 2) implementing → pr_open
      terminal: done · failed · skipped
  """

  use Ecto.Schema
  import Ecto.Changeset

  @pipeline_states ~w(incoming triaging triaged planning plan_ready implementing pr_open done failed skipped)

  schema "issues" do
    field :repo, :string
    field :number, :integer
    field :github_id, :integer
    field :title, :string
    field :body, :string
    field :state, :string, default: "open"
    field :labels, {:array, :string}, default: []
    field :author, :string
    field :url, :string
    field :comments_count, :integer, default: 0
    field :github_updated_at, :utc_datetime_usec
    field :pipeline_state, :string, default: "incoming"
    field :last_synced_at, :utc_datetime_usec
    field :pr_url, :string
    field :pr_number, :integer
    field :auto_demoted, :boolean, default: false
    field :dismissed_at, :utc_datetime_usec

    has_many :triages, Harness.GitHub.TriageDecision
    has_many :plans, Harness.GitHub.Plan
    has_many :outcomes, Harness.GitHub.TriageOutcome

    timestamps(type: :utc_datetime_usec)
  end

  def pipeline_states, do: @pipeline_states

  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [
      :repo,
      :number,
      :github_id,
      :title,
      :body,
      :state,
      :labels,
      :author,
      :url,
      :comments_count,
      :github_updated_at,
      :pipeline_state,
      :last_synced_at,
      :pr_url,
      :pr_number,
      :auto_demoted,
      :dismissed_at
    ])
    |> validate_required([:repo, :number, :github_id, :title])
    |> validate_inclusion(:pipeline_state, @pipeline_states)
    |> validate_inclusion(:state, ~w(open closed))
    |> unique_constraint([:repo, :number])
  end

  @doc "Board column for a pipeline state (drives IssuesLive)."
  def column("incoming"), do: :incoming
  def column("triaging"), do: :incoming
  def column("triaged"), do: :triaged
  def column("planning"), do: :in_progress
  def column("implementing"), do: :in_progress
  def column("plan_ready"), do: :review
  def column("pr_open"), do: :review
  def column(state) when state in ~w(done failed skipped), do: :done
end
