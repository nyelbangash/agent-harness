defmodule Harness.GitHub.RepoState do
  @moduledoc "Per-repo polling bookkeeping: ETag, last poll, cached default branch."

  use Ecto.Schema
  import Ecto.Changeset

  schema "repo_states" do
    field :repo, :string
    field :etag, :string
    field :last_polled_at, :utc_datetime_usec
    field :last_status, :integer
    field :default_branch, :string
    field :pr_comments_since, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(repo_state, attrs) do
    repo_state
    |> cast(attrs, [:repo, :etag, :last_polled_at, :last_status, :default_branch, :pr_comments_since])
    |> validate_required([:repo])
    |> unique_constraint([:repo])
  end
end
