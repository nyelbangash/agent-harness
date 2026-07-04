defmodule Harness.GitHub.TriageDecision do
  @moduledoc """
  One triage pass over an issue. `proposed_route` is what the model said
  (nil when it never produced a valid contract); `final_route` is what policy
  decided — the two-column split keeps "model proposes, policy disposes"
  auditable. An Opus re-triage is a second row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @routes ~w(auto plan skip)
  @scopes ~w(xs s m l)

  schema "triages" do
    belongs_to :issue, Harness.GitHub.Issue
    belongs_to :run, Harness.Runs.Run

    field :proposed_route, :string
    field :confidence, :float
    field :reasoning, :string
    field :estimated_scope, :string
    field :risk_flags, {:array, :string}, default: []
    field :final_route, :string
    field :decision_reason, :string
    field :model, :string
    field :attempt, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  def routes, do: @routes
  def scopes, do: @scopes

  def changeset(triage, attrs) do
    triage
    |> cast(attrs, [
      :issue_id,
      :run_id,
      :proposed_route,
      :confidence,
      :reasoning,
      :estimated_scope,
      :risk_flags,
      :final_route,
      :decision_reason,
      :model,
      :attempt
    ])
    |> validate_required([:issue_id, :final_route, :decision_reason])
    |> validate_inclusion(:final_route, @routes)
    |> validate_inclusion(:proposed_route, @routes)
    |> validate_inclusion(:estimated_scope, @scopes)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:issue_id)
  end
end
