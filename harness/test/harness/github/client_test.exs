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

  test "create_issue/4 happy path: creates issue and returns number + url" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert ["Bearer test-pat"] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["2022-11-28"] = Plug.Conn.get_req_header(conn, "x-github-api-version")

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["title"] == "Epic title"
      assert payload["body"] == "Epic body"
      assert payload["assignees"] == ["nyelbangash"]

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"number" => 42, "html_url" => "https://github.com/owner/repo/issues/42"})
    end)

    assert {:ok, %{number: 42, url: "https://github.com/owner/repo/issues/42"}} =
             Client.create_issue("owner/repo", "Epic title", "Epic body",
               assignees: ["nyelbangash"]
             )
  end

  test "create_issue/4 failure: returns http_status error" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "Validation Failed"})
    end)

    assert {:error, {:http_status, 422}} =
             Client.create_issue("owner/repo", "title", "body")
  end

  test "update_issue/3 happy path: returns :ok" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path =~ "/issues/42"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["body"] =~ "new body"

      Req.Test.json(conn, %{"number" => 42})
    end)

    assert :ok = Client.update_issue("owner/repo", 42, %{body: "new body"})
  end
end
