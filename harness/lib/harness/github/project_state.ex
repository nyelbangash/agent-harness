defmodule Harness.GitHub.ProjectState do
  @moduledoc "Per-project-board polling bookkeeping: last poll, last status (mirrors `RepoState`)."

  use Ecto.Schema
  import Ecto.Changeset

  schema "project_states" do
    field :owner, :string
    field :number, :integer
    field :last_polled_at, :utc_datetime_usec
    field :last_status, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project_state, attrs) do
    project_state
    |> cast(attrs, [:owner, :number, :last_polled_at, :last_status])
    |> validate_required([:owner, :number])
    |> unique_constraint([:owner, :number])
  end
end
