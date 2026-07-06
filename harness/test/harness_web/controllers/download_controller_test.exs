defmodule HarnessWeb.DownloadControllerTest do
  use HarnessWeb.ConnCase, async: false

  alias Harness.{Compose, Ideation}

  @moduletag :capture_log

  defp new_session(attrs \\ %{}) do
    {session, root} =
      Ideation.start_session(
        Map.merge(%{seed_prompt: "a better todo app", budget_minutes: 180}, attrs)
      )

    %{session: session, root: root}
  end

  describe "GET /ideation/:id/synthesis.md" do
    test "404 when synthesis is not yet present", %{conn: conn} do
      %{session: session} = new_session()
      # session dirs are keyed by (reused) session id and not rolled back with
      # the DB sandbox, so clear any leftover SYNTHESIS.md from a prior run.
      File.rm(Ideation.synthesis_path(session))
      conn = get(conn, ~p"/ideation/#{session.id}/synthesis.md")
      assert conn.status == 404
    end

    test "downloads the synthesis file when present", %{conn: conn} do
      %{session: session} = new_session()
      File.write!(Ideation.synthesis_path(session), "# Final synthesis")

      conn = get(conn, ~p"/ideation/#{session.id}/synthesis.md")

      assert conn.status == 200
      assert conn.resp_body == "# Final synthesis"

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "session-#{session.id}-synthesis.md"
    end

    test "raises Ecto.NoResultsError for a nonexistent session id", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn ->
        get(conn, ~p"/ideation/999999/synthesis.md")
      end
    end
  end

  describe "GET /ideation/:id/journal.md" do
    test "downloads the journal", %{conn: conn} do
      %{session: session} = new_session()
      conn = get(conn, ~p"/ideation/#{session.id}/journal.md")

      assert conn.status == 200
      assert conn.resp_body =~ "a better todo app"
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "session-#{session.id}-journal.md"
    end
  end

  describe "GET /ideation/nodes/:idea_id/artifact.md" do
    test "downloads a node's artifact, filename derived from the on-disk path", %{conn: conn} do
      %{session: session, root: root} = new_session()
      idea = Ideation.add_child!(session, root, %{title: "a", score: 6.0}, "artifact body")

      conn = get(conn, ~p"/ideation/nodes/#{idea.id}/artifact.md")

      assert conn.status == 200
      assert conn.resp_body == "artifact body"
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ Path.basename(idea.artifact_path)
    end

    test "404 when the idea has no artifact", %{conn: conn} do
      %{root: root} = new_session()
      conn = get(conn, ~p"/ideation/nodes/#{root.id}/artifact.md")
      assert conn.status == 404
    end

    test "raises Ecto.NoResultsError for a nonexistent idea id", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn ->
        get(conn, ~p"/ideation/nodes/999999/artifact.md")
      end
    end
  end

  describe "GET /ideation/:id/export.zip" do
    test "downloads a zip containing journal and node artifacts", %{conn: conn} do
      %{session: session, root: root} = new_session()
      idea = Ideation.add_child!(session, root, %{title: "a", score: 6.0}, "artifact body")

      conn = get(conn, ~p"/ideation/#{session.id}/export.zip")

      assert conn.status == 200
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "session-#{session.id}.zip"

      {:ok, entries} = :zip.unzip(conn.resp_body, [:memory])
      names = Enum.map(entries, fn {name, _} -> to_string(name) end)
      assert "JOURNAL.md" in names
      assert Path.basename(idea.artifact_path) in names
    end
  end

  describe "GET /compose/:id/draft.md" do
    test "downloads title+body as markdown independent of filing status", %{conn: conn} do
      draft = Compose.create_draft!(%{prompt: "idea", repo: "owner/fixture"})
      draft = Compose.update_draft!(draft, %{title: "My Title", body: "the body"})

      conn = get(conn, ~p"/compose/#{draft.id}/draft.md")

      assert conn.status == 200
      assert conn.resp_body == "# My Title\n\nthe body"
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "draft-#{draft.id}.md"
    end

    test "404 when the draft has no body yet", %{conn: conn} do
      draft = Compose.create_draft!(%{prompt: "idea", repo: "owner/fixture"})
      conn = get(conn, ~p"/compose/#{draft.id}/draft.md")
      assert conn.status == 404
    end

    test "raises Ecto.NoResultsError for a nonexistent draft id", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn ->
        get(conn, ~p"/compose/999999/draft.md")
      end
    end
  end
end
