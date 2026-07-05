defmodule Harness.GitHub.ClientTest do
  # async: false — swaps global :github_req_options
  use ExUnit.Case, async: false

  alias Harness.GitHub.Client

  setup do
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:harness, :github_req_options) end)
    :ok
  end

  test "newest_issue_comment returns the LAST comment of the created-asc listing" do
    # the per-issue endpoint ignores direction and lists oldest-first; taking
    # the head instead of the tail caused the #48 slow loop
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.params["per_page"] == "100"

      Req.Test.json(conn, [
        %{"id" => 1, "body" => "oldest", "created_at" => "2026-07-01T00:00:00Z"},
        %{"id" => 2, "body" => "newest", "created_at" => "2026-07-05T00:00:00Z"}
      ])
    end)

    assert {:ok, %{"id" => 2, "body" => "newest"}} = Client.newest_issue_comment("o/r", 5)
  end

  test "viewer_login returns the PAT owner's login" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert ["Bearer test-pat"] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["2022-11-28"] = Plug.Conn.get_req_header(conn, "x-github-api-version")
      Req.Test.json(conn, %{"login" => "nyelbangash"})
    end)

    assert {:ok, "nyelbangash"} = Client.viewer_login()
  end

  test "viewer_login surfaces 401 as the expired-token signal" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
    end)

    assert {:error, :unauthorized} = Client.viewer_login()
  end

  test "list_assigned_issues filters pull requests and returns the etag" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["assignee"] == "nyelbangash"
      assert conn.query_params["state"] == "open"

      conn
      |> Plug.Conn.put_resp_header("etag", ~s(W/"abc123"))
      |> Req.Test.json([
        %{"number" => 1, "title" => "real issue"},
        %{"number" => 2, "title" => "a PR in disguise", "pull_request" => %{"url" => "..."}}
      ])
    end)

    assert {:ok, issues, etag} = Client.list_assigned_issues("owner/repo", "nyelbangash")
    assert [%{"number" => 1}] = issues
    assert etag == ~s(W/"abc123")
  end

  test "list_assigned_issues sends If-None-Match and honors 304" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert [~s(W/"abc123")] = Plug.Conn.get_req_header(conn, "if-none-match")
      Plug.Conn.send_resp(conn, 304, "")
    end)

    assert :not_modified =
             Client.list_assigned_issues("owner/repo", "nyelbangash", ~s(W/"abc123"))
  end

  test "post_issue_comment returns comment id and created_at" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"id" => 987, "created_at" => "2026-07-05T10:00:00Z"})
    end)

    assert {:ok, 987, "2026-07-05T10:00:00Z"} =
             Client.post_issue_comment("owner/repo", 5, "plan attached")
  end

  test "newest_issue_comment returns nil when there are no comments" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, [])
    end)

    assert {:ok, nil} = Client.newest_issue_comment("owner/repo", 5)
  end

  test "get_pull_request returns state/merged/merge_commit_sha" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "state" => "closed",
        "merged" => true,
        "merge_commit_sha" => "abc123"
      })
    end)

    assert {:ok, %{state: "closed", merged: true, merge_commit_sha: "abc123"}} =
             Client.get_pull_request("owner/repo", 42)
  end

  test "get_pull_request returns :not_found on 404" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    assert {:error, :not_found} = Client.get_pull_request("owner/repo", 99)
  end

  test "list_pull_request_commits returns a list of commit objects" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, [%{"sha" => "a1"}, %{"sha" => "b2"}])
    end)

    assert {:ok, [%{"sha" => "a1"}, %{"sha" => "b2"}]} =
             Client.list_pull_request_commits("owner/repo", 42)
  end
end
