defmodule Harness.GitHub.ClientTest do
  # async: false — swaps global :github_req_options
  use ExUnit.Case, async: false

  alias Harness.GitHub.Client

  setup do
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:harness, :github_req_options) end)
    :ok
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

  test "post_issue_comment returns the comment id" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 987})
    end)

    assert {:ok, 987} = Client.post_issue_comment("owner/repo", 5, "plan attached")
  end
end
