defmodule Harness.Ideation.Promotion do
  @moduledoc "Tracks a promote-to-epic operation for an idea node."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(running succeeded failed)

  schema "ideation_promotions" do
    belongs_to :idea, Harness.Ideation.Idea
    belongs_to :session, Harness.Ideation.Session
    belongs_to :run, Harness.Runs.Run

    field :target_repo, :string
    field :epic_number, :integer
    field :epic_url, :string
    field :status, :string, default: "running"
    field :error_detail, :string

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(promotion, attrs) do
    promotion
    |> cast(attrs, [
      :idea_id,
      :session_id,
      :run_id,
      :target_repo,
      :epic_number,
      :epic_url,
      :status,
      :error_detail
    ])
    |> validate_required([:idea_id, :session_id, :target_repo])
    |> validate_inclusion(:status, @statuses)
  end
end
