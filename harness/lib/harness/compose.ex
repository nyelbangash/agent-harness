defmodule Harness.Compose do
  @moduledoc """
  Context for the Issue Composer: draft lifecycle, approval (files the issue),
  and discard. PubSub topic "compose".
  """

  import Ecto.Query
  alias Harness.Compose.IssueDraft
  alias Harness.GitHub.{Client, Provenance}
  alias Harness.Repo

  @topic "compose"

  def subscribe, do: Phoenix.PubSub.subscribe(Harness.PubSub, @topic)

  # -- drafts -----------------------------------------------------------------

  def create_draft!(attrs) do
    %IssueDraft{}
    |> IssueDraft.changeset(attrs)
    |> Repo.insert!()
    |> tap(&broadcast({:draft_created, &1}))
  end

  def get_draft!(id), do: Repo.get!(IssueDraft, id)

  def list_drafts do
    from(d in IssueDraft,
      where: d.status != "discarded",
      order_by: [desc: d.inserted_at],
      preload: [:run]
    )
    |> Repo.all()
  end

  def update_draft!(draft, attrs) do
    draft
    |> IssueDraft.changeset(attrs)
    |> Repo.update!()
    |> tap(&broadcast({:draft_updated, &1}))
  end

  # -- lifecycle --------------------------------------------------------------

  @doc """
  Files the draft as a GitHub issue (self-assigned, provenance-stamped),
  marks it approved, and returns the updated draft. Raises on GitHub failure.
  """
  def approve_draft!(%IssueDraft{status: "draft"} = draft) do
    with {:ok, login} <- Client.viewer_login() do
      stamped_body = Provenance.stamp(draft.body, "compose", draft.run_id || "none")

      case Client.create_issue(draft.repo, draft.title, stamped_body, assignees: [login]) do
        {:ok, _} ->
          {:ok, update_draft!(draft, %{status: "approved"})}

        {:error, {:http_status, 403}} ->
          {:error, :forbidden_check_pat_scope}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def discard_draft!(%IssueDraft{} = draft) do
    update_draft!(draft, %{status: "discarded"})
  end

  # -- internals --------------------------------------------------------------

  defp broadcast(msg) do
    Phoenix.PubSub.broadcast(Harness.PubSub, @topic, msg)
  end
end
