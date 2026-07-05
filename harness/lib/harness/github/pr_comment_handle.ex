defmodule Harness.GitHub.PrCommentHandle do
  @moduledoc """
  Deduplication record for operator PR comments that the poll sweep has
  decided to act on. The unique index on (repo, comment_id, comment_type)
  is the idempotency guarantee — insert-on-conflict-nothing is the
  poll-safe pattern (mirrors TriageOutcome).

  `action` is nil until RespondWorker completes; `run_id` is nil until
  the Phase 2 fix session (or the decline Phase 1 run) is recorded.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "pr_comment_handles" do
    field :repo, :string
    field :pr_number, :integer
    field :comment_id, :integer
    field :comment_type, :string
    field :action, :string
    field :run_id, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(handle, attrs) do
    handle
    |> cast(attrs, [:repo, :pr_number, :comment_id, :comment_type, :action, :run_id])
    |> validate_required([:repo, :pr_number, :comment_id, :comment_type])
    |> validate_inclusion(:comment_type, ~w(review issue))
    |> validate_inclusion(:action, ~w(fix decline_with_reason))
    |> unique_constraint([:repo, :comment_id, :comment_type])
  end
end
