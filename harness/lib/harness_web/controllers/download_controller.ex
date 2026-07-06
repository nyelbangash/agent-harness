defmodule HarnessWeb.DownloadController do
  @moduledoc """
  Raw-markdown/zip downloads for ideation artifacts and compose drafts.
  Every action resolves the underlying path from a server-side lookup
  (`session_id`/`idea_id`/`draft_id` → DB record → known path) — none of them
  accept a client-supplied filename or path fragment.
  """

  use HarnessWeb, :controller

  alias Harness.{Compose, Ideation}

  def synthesis(conn, %{"id" => id}) do
    session = Ideation.get_session!(id)

    case Ideation.read_synthesis(session) do
      nil ->
        conn |> put_status(404) |> text("not found")

      content ->
        send_download(conn, {:binary, content}, filename: "session-#{id}-synthesis.md")
    end
  end

  def journal(conn, %{"id" => id}) do
    session = Ideation.get_session!(id)
    content = Ideation.read_journal(session)
    send_download(conn, {:binary, content}, filename: "session-#{id}-journal.md")
  end

  def node(conn, %{"idea_id" => idea_id}) do
    idea = Ideation.get_idea!(idea_id)

    case Ideation.read_artifact(idea) do
      nil ->
        conn |> put_status(404) |> text("not found")

      content ->
        filename = Path.basename(idea.artifact_path)
        send_download(conn, {:binary, content}, filename: filename)
    end
  end

  def zip(conn, %{"id" => id}) do
    session = Ideation.get_session!(id)

    case Ideation.export_zip(session) do
      {:ok, bin} ->
        send_download(conn, {:binary, bin}, filename: "session-#{id}.zip")

      {:error, _reason} ->
        conn |> put_status(500) |> text("could not build export")
    end
  end

  def draft(conn, %{"id" => id}) do
    draft = Compose.get_draft!(id)

    if draft.body do
      content = "# #{draft.title}\n\n#{draft.body}"
      send_download(conn, {:binary, content}, filename: "draft-#{id}.md")
    else
      conn |> put_status(404) |> text("not found")
    end
  end

  def draft_attachment(conn, %{"id" => id, "filename" => filename}) do
    draft = Compose.get_draft!(id)
    serve_attachment(conn, Compose.attachments(draft), filename)
  end

  def ideation_attachment(conn, %{"id" => id, "filename" => filename}) do
    session = Ideation.get_session!(id)
    serve_attachment(conn, Ideation.attachments(session), filename)
  end

  defp serve_attachment(conn, attachments, filename) do
    case Enum.find(attachments, &(&1["filename"] == filename)) do
      nil ->
        conn |> put_status(404) |> text("not found")

      %{"path" => path} ->
        send_file(conn, 200, path)
    end
  end
end
