defmodule Harness.GitHub.TriageOutcome do
  use Ecto.Schema
  import Ecto.Changeset

  @outcomes ~w(merged_untouched merged_amended pr_closed_unmerged
               plan_executed issue_closed_no_action demoted)

  schema "triage_outcomes" do
    belongs_to :issue, Harness.GitHub.Issue
    belongs_to :triage, Harness.GitHub.TriageDecision

    field :outcome, :string
    field :resolved_at, :utc_datetime_usec
    field :days_open, :float
    field :amend_commit_count, :integer
    field :shadow, :boolean, default: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def outcomes, do: @outcomes

  def changeset(to, attrs) do
    to
    |> cast(attrs, [:issue_id, :triage_id, :outcome, :resolved_at,
                    :days_open, :amend_commit_count, :shadow])
    |> validate_required([:issue_id, :outcome, :resolved_at, :days_open])
    |> validate_inclusion(:outcome, @outcomes)
    |> unique_constraint(:issue_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:triage_id)
  end
end
