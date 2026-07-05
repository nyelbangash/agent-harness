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

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def newest_issue_comment(repo, number) do
    # the per-issue comments endpoint IGNORES sort/direction (fixed created-asc;
    # only the repo-level /issues/comments endpoint sorts) — per_page:1 + desc
    # silently returned the OLDEST comment, which made harness_caused_update?
    # fail for any issue with >1 comment (the #48 slow loop). Fetch a full page
    # and take the last.
    case request(:get, "/repos/#{repo}/issues/#{number}/comments", params: [per_page: 100]) do
      {:ok, %{status: 200, body: [_ | _] = comments}} -> {:ok, List.last(comments)}
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

  @doc "Create an issue. Returns `{:ok, %{number: n, url: html_url}}`. opts: assignees, labels."
  def create_issue(repo, title, body, opts \\ []) do
    payload =
      %{title: title, body: body}
      |> maybe_put(:assignees, Keyword.get(opts, :assignees, []))
      |> maybe_put(:labels, Keyword.get(opts, :labels, []))

    case request(:post, "/repos/#{repo}/issues", json: payload) do
      {:ok, %{status: 201, body: %{"number" => number, "html_url" => url}}} ->
        {:ok, %{number: number, url: url}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Edit an existing issue (PATCH). Used to backfill the epic task list after children are created."
  def edit_issue(repo, number, attrs) do
    case request(:patch, "/repos/#{repo}/issues/#{number}", json: attrs) do
      {:ok, %{status: 200}} -> :ok
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
      {:ok,
       %{status: 200, body: %{"state" => state, "merged" => merged, "merge_commit_sha" => sha}}} ->
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
    case request(:get, "/repos/#{repo}/pulls/#{number}/commits", params: [per_page: 100]) do
      {:ok, %{status: 200, body: commits}} when is_list(commits) ->
        {:ok, commits}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Post a PR review. `event` is \"APPROVE\" | \"REQUEST_CHANGES\" | \"COMMENT\"."
  def create_pull_request_review(repo, pr_number, event, body) do
    case request(:post, "/repos/#{repo}/pulls/#{pr_number}/reviews",
           json: %{body: body, event: event}
         ) do
      {:ok, %{status: 200, body: %{"id" => id}}} ->
        {:ok, %{id: id}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Inline diff comments on a PR since an ISO8601 timestamp (nil = all)."
  def list_pr_review_comments(repo, pr_number, since \\ nil) do
    params = Keyword.reject([per_page: 100, since: since], fn {_, v} -> is_nil(v) end)

    case request(:get, "/repos/#{repo}/pulls/#{pr_number}/comments", params: params) do
      {:ok, %{status: 200, body: comments}} when is_list(comments) -> {:ok, comments}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "PR conversation comments (issues endpoint) since an ISO8601 timestamp (nil = all)."
  def list_pr_issue_comments(repo, pr_number, since \\ nil) do
    params = Keyword.reject([per_page: 100, since: since], fn {_, v} -> is_nil(v) end)

    case request(:get, "/repos/#{repo}/issues/#{pr_number}/comments", params: params) do
      {:ok, %{status: 200, body: comments}} when is_list(comments) -> {:ok, comments}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Post a threaded reply to an inline review comment. Returns `{:ok, id, created_at}`."
  def post_pr_review_comment_reply(repo, pr_number, comment_id, body) do
    case request(:post, "/repos/#{repo}/pulls/#{pr_number}/comments/#{comment_id}/replies",
           json: %{body: body}
         ) do
      {:ok, %{status: 201, body: %{"id" => id, "created_at" => created_at}}} ->
        {:ok, id, created_at}

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

  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
