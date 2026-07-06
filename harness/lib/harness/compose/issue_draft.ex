defmodule Harness.Compose.IssueDraft do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(draft approved discarded)

  schema "issue_drafts" do
    field :prompt, :string
    field :repo, :string
    field :title, :string
    field :body, :string
    field :scope_hint, :string
    field :open_questions, :string
    field :status, :string, default: "draft"
    field :attachments, :string
    belongs_to :run, Harness.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [
      :prompt,
      :repo,
      :run_id,
      :title,
      :body,
      :scope_hint,
      :open_questions,
      :status,
      :attachments
    ])
    |> validate_required([:prompt, :repo])
    |> validate_inclusion(:status, @statuses)
  end
end
