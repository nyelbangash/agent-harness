defmodule Harness.Ideation.Idea do
  @moduledoc """
  A node in the idea tree (spec §5.1). Structure + metadata live here; the
  actual thinking lives in the markdown `artifact_path` file, so sessions
  survive restarts and resume mid-tree. Pruned nodes are marked, never
  deleted (the UI dims them rather than hiding them).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(seed frontier expanded pruned synthesized)

  schema "ideas" do
    belongs_to :session, Harness.Ideation.Session
    belongs_to :parent, __MODULE__

    field :depth, :integer, default: 0
    field :title, :string
    field :summary, :string
    field :status, :string, default: "seed"
    field :score, :float, default: 5.0
    field :artifact_path, :string
    field :model_used, :string
    field :tokens_in, :integer, default: 0
    field :tokens_out, :integer, default: 0
    field :promoted_epic_url, :string
    field :promoted_epic_number, :integer

    has_many :children, __MODULE__, foreign_key: :parent_id

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(idea, attrs) do
    idea
    |> cast(attrs, [
      :session_id,
      :parent_id,
      :depth,
      :title,
      :summary,
      :status,
      :score,
      :artifact_path,
      :model_used,
      :tokens_in,
      :tokens_out,
      :promoted_epic_url,
      :promoted_epic_number
    ])
    |> validate_required([:session_id, :title])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 10.0)
  end
end
