defmodule Harness.Runs.Run do
  @moduledoc """
  One headless agent session (spec §6). `result_subtype` carries the CLI's
  result envelope subtype — status derivation branches on it, never on
  `is_error`. `os_pid` exists so kill switches (UI and `mix harness.stop`)
  can signal the OS process without BEAM distribution.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(triage implement plan ideate critique review promote respond explore manager)
  @statuses ~w(queued running verifying pushing opening_pr succeeded failed killed)

  schema "runs" do
    field :kind, :string
    field :ref, :string
    belongs_to :issue, Harness.GitHub.Issue

    field :model, :string
    field :status, :string, default: "queued"
    field :turns, :integer, default: 0
    field :tokens_in, :integer, default: 0
    field :tokens_out, :integer, default: 0
    field :cost_estimate, :float
    field :used_overage, :boolean, default: false
    field :worktree, :string
    field :session_id, :string
    field :os_pid, :integer
    field :exit_code, :integer
    field :result_subtype, :string
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    has_many :events, Harness.Runs.RunEvent

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :kind,
      :ref,
      :issue_id,
      :model,
      :status,
      :turns,
      :tokens_in,
      :tokens_out,
      :cost_estimate,
      :used_overage,
      :worktree,
      :session_id,
      :os_pid,
      :exit_code,
      :result_subtype,
      :error,
      :started_at,
      :ended_at
    ])
    |> validate_required([:kind, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
  end
end
