defmodule Harness.Ideation.Session do
  @moduledoc """
  One ideation run (spec §5.1). The seed prompt is the anchor — included
  verbatim in every iteration's context to prevent drift. Counters
  (`iterations`, `critiques`, `no_progress_streak`) drive the stop
  conditions; the tree in `ideas` is the memory (fresh model context each
  iteration).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(running stopped synthesized failed)
  @modes ~w(explore refine)

  schema "ideation_sessions" do
    field :seed_prompt, :string
    field :mode, :string, default: "explore"
    field :budget_minutes, :integer, default: 180
    field :status, :string, default: "running"
    field :stop_reason, :string
    field :iterations, :integer, default: 0
    field :critiques, :integer, default: 0
    field :no_progress_streak, :integer, default: 0
    field :synthesis_path, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    has_many :ideas, Harness.Ideation.Idea

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def modes, do: @modes

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :seed_prompt,
      :mode,
      :budget_minutes,
      :status,
      :stop_reason,
      :iterations,
      :critiques,
      :no_progress_streak,
      :synthesis_path,
      :started_at,
      :ended_at
    ])
    |> validate_required([:seed_prompt])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:mode, @modes)
    |> validate_number(:budget_minutes, greater_than: 0)
  end
end
