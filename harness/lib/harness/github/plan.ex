defmodule Harness.GitHub.Plan do
  @moduledoc """
  A produced plan packet (PLAN.md + CONTEXT.md), persisted under
  `~/.harness/plans/` so it outlives the run's worktree. Re-planning an issue
  supersedes earlier rows; Phase 2's promote-to-auto flips `status`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(ready superseded promoted)

  schema "plans" do
    belongs_to :issue, Harness.GitHub.Issue
    belongs_to :run, Harness.Runs.Run

    field :plan_path, :string
    field :context_path, :string
    field :branch, :string
    field :issue_comment_id, :integer
    field :summary, :string
    field :status, :string, default: "ready"

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :issue_id,
      :run_id,
      :plan_path,
      :context_path,
      :branch,
      :issue_comment_id,
      :summary,
      :status
    ])
    |> validate_required([:issue_id, :run_id, :plan_path, :context_path])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:issue_id)
  end
end
