defmodule Harness.GitHub.Client do
  @moduledoc """
  Minimal GitHub REST client (fine-grained PAT, `Req`).

  Cheap-polling contract (all verified against live docs, July 2026):

    * per-repo `GET /repos/{repo}/issues?assignee=LOGIN&state=open` — works
      with fine-grained PATs (Issues read)
    * authorized conditional requests are free: send `If-None-Match` with the
      stored ETag; a 304 does not count against the rate limit
    * every "issues" listing interleaves pull requests — drop items carrying
      a `pull_request` key
    * pin `X-GitHub-Api-Version: 2022-11-28`
  """

  @api_version "2022-11-28"

  def viewer_login do
    case request(:get, "/user") do
      {:ok, %{status: 200, body: %{"login" => login}}} -> {:ok, login}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Open issues assigned to `assignee` in `repo`, with ETag support.
  Returns `:not_modified`, `{:ok, issues, etag}`, or `{:error, reason}`.
  """
  def list_assigned_issues(repo, assignee, etag \\ nil) do
    headers = if etag, do: [{"if-none-match", etag}], else: []

    case request(:get, "/repos/#{repo}/issues",
           params: [assignee: assignee, state: "open", per_page: 100],
           headers: headers
         ) do
      {:ok, %{status: 304}} ->
        :not_modified

      {:ok, %{status: 200, body: items} = resp} when is_list(items) ->
        issues = Enum.reject(items, &Map.has_key?(&1, "pull_request"))
        {:ok, issues, first_header(resp, "etag")}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_issue_comments(repo, number) do
    case request(:get, "/repos/#{repo}/issues/#{number}/comments", params: [per_page: 50]) do
      {:ok, %{status: 200, body: comments}} when is_list(comments) -> {:ok, comments}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def post_issue_comment(repo, number, body) do
    case request(:post, "/repos/#{repo}/issues/#{number}/comments", json: %{body: body}) do
      {:ok, %{status: 201, body: %{"id" => id, "created_at" => created_at}}} ->
        {:ok, id, created_at}

      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def newest_issue_comment(repo, number) do
    case request(:get, "/repos/#{repo}/issues/#{number}/comments",
           params: [per_page: 1, direction: "desc"]) do
      {:ok, %{status: 200, body: [comment | _]}} -> {:ok, comment}
      {:ok, %{status: 200, body: []}} -> {:ok, nil}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fetch one issue's current `updated_at` (self-acknowledge after harness writes)."
  def issue_updated_at(repo, number) do
    case request(:get, "/repos/#{repo}/issues/#{number}", []) do
      {:ok, %{status: 200, body: %{"updated_at" => updated_at}}} -> {:ok, updated_at}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Open a PR. Returns `{:ok, %{number: n, url: html_url}}`."
  def create_pull_request(repo, head, base, title, body) do
    case request(:post, "/repos/#{repo}/pulls",
           json: %{title: title, head: head, base: base, body: body}
         ) do
      {:ok, %{status: 201, body: %{"number" => number, "html_url" => url}}} ->
        {:ok, %{number: number, url: url}}

      {:ok, %{status: 422, body: body}} ->
        # usually "A pull request already exists for ..." on a re-run
        {:error, {:unprocessable, body}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Fetch a single PR by number. Returns at least state, merged, merge_commit_sha."
  def get_pull_request(repo, number) do
    case request(:get, "/repos/#{repo}/pulls/#{number}") do
      {:ok, %{status: 200, body: %{"state" => state, "merged" => merged,
                                   "merge_commit_sha" => sha}}} ->
        {:ok, %{state: state, merged: merged, merge_commit_sha: sha}}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List commits on a PR (up to 100). Used for amended-vs-untouched attribution."
  def list_pull_request_commits(repo, number) do
    case request(:get, "/repos/#{repo}/pulls/#{number}/commits",
                 params: [per_page: 100]) do
      {:ok, %{status: 200, body: commits}} when is_list(commits) ->
        {:ok, commits}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Find the open PR whose head is `head` (e.g. \"owner:branch\"), for 422 reconciliation."
  def find_pull_request(repo, head) do
    case request(:get, "/repos/#{repo}/pulls", params: [head: head, state: "open", per_page: 1]) do
      {:ok, %{status: 200, body: [%{"number" => n, "html_url" => u} | _]}} ->
        {:ok, %{number: n, url: u}}

      {:ok, %{status: 200, body: []}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, path, opts \\ []) do
    with {:ok, pat} <- Harness.Secrets.github_pat() do
      headers =
        [
          {"authorization", "Bearer #{pat}"},
          {"x-github-api-version", @api_version}
        ] ++ Keyword.get(opts, :headers, [])

      Req.request(
        [
          method: method,
          url: base_url() <> path,
          headers: headers,
          retry: false,
          receive_timeout: 30_000
        ] ++
          Keyword.take(opts, [:params, :json]) ++
          Application.get_env(:harness, :github_req_options, [])
      )
    else
      {:error, :not_found} -> {:error, :no_pat}
    end
  end

  defp first_header(resp, name) do
    case Req.Response.get_header(resp, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp base_url do
    Application.get_env(:harness, :github_api_base, "https://api.github.com")
  end
end
