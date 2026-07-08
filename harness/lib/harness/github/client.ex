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

  @doc "The PAT owner's login. Pass `owner` to resolve via that owner's PAT (see `Secrets.github_pat_for_owner/1`)."
  def viewer_login(owner \\ nil) do
    target = if owner, do: {:owner, owner}, else: nil

    case request(target, :get, "/user") do
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

    case request(repo, :get, "/repos/#{repo}/issues",
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
    case request(repo, :get, "/repos/#{repo}/issues/#{number}/comments", params: [per_page: 50]) do
      {:ok, %{status: 200, body: comments}} when is_list(comments) -> {:ok, comments}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def post_issue_comment(repo, number, body) do
    case request(repo, :post, "/repos/#{repo}/issues/#{number}/comments", json: %{body: body}) do
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
    case request(repo, :get, "/repos/#{repo}/issues/#{number}/comments", params: [per_page: 100]) do
      {:ok, %{status: 200, body: [_ | _] = comments}} -> {:ok, List.last(comments)}
      {:ok, %{status: 200, body: []}} -> {:ok, nil}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fetch one issue's current `updated_at` (self-acknowledge after harness writes)."
  def issue_updated_at(repo, number) do
    case request(repo, :get, "/repos/#{repo}/issues/#{number}", []) do
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

    case request(repo, :post, "/repos/#{repo}/issues", json: payload) do
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
    case request(repo, :patch, "/repos/#{repo}/issues/#{number}", json: attrs) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Open a PR. Returns `{:ok, %{number: n, url: html_url}}`."
  def create_pull_request(repo, head, base, title, body) do
    case request(repo, :post, "/repos/#{repo}/pulls",
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

  @doc """
  Fetch a single PR by number. Returns state, merged, merge_commit_sha,
  mergeable, mergeable_state, and head_ref.

  GitHub computes `mergeable` asynchronously — if the first response returns
  `null`, this polls up to 3 more times (2 s apart) before giving up.
  """
  def get_pull_request(repo, number) do
    case do_get_pull_request(repo, number) do
      {:ok, %{mergeable: nil}} -> wait_for_mergeability(repo, number, 3)
      result -> result
    end
  end

  defp do_get_pull_request(repo, number) do
    case request(repo, :get, "/repos/#{repo}/pulls/#{number}") do
      {:ok,
       %{
         status: 200,
         body: %{
           "state" => state,
           "merged" => merged,
           "merge_commit_sha" => sha,
           "mergeable" => mergeable,
           "mergeable_state" => mergeable_state,
           "head" => %{"ref" => head_ref}
         }
       }} ->
        {:ok,
         %{
           state: state,
           merged: merged,
           merge_commit_sha: sha,
           mergeable: mergeable,
           mergeable_state: mergeable_state,
           head_ref: head_ref
         }}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_mergeability(_repo, _number, 0), do: {:error, :mergeability_timeout}

  defp wait_for_mergeability(repo, number, remaining) do
    Process.sleep(2_000)

    case do_get_pull_request(repo, number) do
      {:ok, %{mergeable: nil}} -> wait_for_mergeability(repo, number, remaining - 1)
      result -> result
    end
  end

  @doc "List commits on a PR (up to 100). Used for amended-vs-untouched attribution."
  def list_pull_request_commits(repo, number) do
    case request(repo, :get, "/repos/#{repo}/pulls/#{number}/commits", params: [per_page: 100]) do
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
    case request(repo, :post, "/repos/#{repo}/pulls/#{pr_number}/reviews",
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

    case request(repo, :get, "/repos/#{repo}/pulls/#{pr_number}/comments", params: params) do
      {:ok, %{status: 200, body: comments}} when is_list(comments) -> {:ok, comments}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "PR conversation comments (issues endpoint) since an ISO8601 timestamp (nil = all)."
  def list_pr_issue_comments(repo, pr_number, since \\ nil) do
    params = Keyword.reject([per_page: 100, since: since], fn {_, v} -> is_nil(v) end)

    case request(repo, :get, "/repos/#{repo}/issues/#{pr_number}/comments", params: params) do
      {:ok, %{status: 200, body: comments}} when is_list(comments) -> {:ok, comments}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Post a threaded reply to an inline review comment. Returns `{:ok, id, created_at}`."
  def post_pr_review_comment_reply(repo, pr_number, comment_id, body) do
    case request(repo, :post, "/repos/#{repo}/pulls/#{pr_number}/comments/#{comment_id}/replies",
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
    case request(repo, :get, "/repos/#{repo}/pulls",
           params: [head: head, state: "open", per_page: 1]
         ) do
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

  @doc """
  POST a GraphQL query, authenticated as `owner`'s PAT (Projects v2 has no
  REST surface — see `Secrets.github_pat_for_owner/1`). GraphQL returns HTTP
  200 even for query errors (missing-scope/permission problems surface as a
  top-level `"errors"` array, not 401/403) — `{:ok, data}` is only returned
  when that array is absent or empty.
  """
  def graphql(owner, query, variables \\ %{}) do
    pat_result = Harness.Secrets.github_pat_for_owner(owner)

    with {:ok, pat} <- pat_result do
      headers = [
        {"authorization", "Bearer #{pat}"},
        {"x-github-api-version", @api_version}
      ]

      result =
        Req.request(
          [
            method: :post,
            url: base_url() <> "/graphql",
            headers: headers,
            json: %{query: query, variables: variables},
            retry: false,
            receive_timeout: 30_000
          ] ++ Application.get_env(:harness, :github_req_options, [])
        )

      case result do
        {:ok, %{status: 200, body: %{"errors" => [_ | _] = errors}}} ->
          {:error, {:graphql_errors, errors}}

        {:ok, %{status: 200, body: %{"data" => data}}} ->
          {:ok, data}

        {:ok, %{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found} -> {:error, :no_pat}
    end
  end

  @project_id_by_org """
  query($login: String!, $number: Int!) {
    organization(login: $login) { projectV2(number: $number) { id } }
  }
  """

  @project_id_by_user """
  query($login: String!, $number: Int!) {
    user(login: $login) { projectV2(number: $number) { id } }
  }
  """

  @project_items_page """
  query($id: ID!, $after: String) {
    node(id: $id) {
      ... on ProjectV2 {
        items(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            content {
              __typename
              ... on Issue {
                number
                title
                body
                state
                url
                databaseId
                updatedAt
                labels(first: 20) { nodes { name } }
                author { login }
                comments { totalCount }
                repository { nameWithOwner }
                assignees(first: 10) { nodes { login } }
              }
              ... on PullRequest { number }
              ... on DraftIssue { title }
            }
            fieldValues(first: 20) {
              nodes {
                __typename
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  field { ... on ProjectV2SingleSelectField { name } }
                }
                ... on ProjectV2ItemFieldTextValue {
                  text
                  field { ... on ProjectV2FieldCommon { name } }
                }
              }
            }
          }
        }
      }
    }
  }
  """

  @doc """
  All items on `owner`'s project `number` (org- or user-owned), paginated to
  completion. Returns `{:ok, [item]}` where each item is
  `%{type: :issue | :pull_request | :draft_issue, ...}`, or `{:error, reason}`
  on the first failing GraphQL call.
  """
  def list_project_items(owner, number) do
    with {:ok, id} <- project_id(owner, number) do
      paginate_items(owner, id, nil, [])
    end
  end

  defp project_id(owner, number) do
    case graphql(owner, @project_id_by_org, %{login: owner, number: number}) do
      {:ok, %{"organization" => %{"projectV2" => %{"id" => id}}}} ->
        {:ok, id}

      _ ->
        case graphql(owner, @project_id_by_user, %{login: owner, number: number}) do
          {:ok, %{"user" => %{"projectV2" => %{"id" => id}}}} -> {:ok, id}
          {:ok, _} -> {:error, :project_not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp paginate_items(owner, id, after_cursor, acc) do
    case graphql(owner, @project_items_page, %{id: id, after: after_cursor}) do
      {:ok, %{"node" => %{"items" => %{"nodes" => nodes, "pageInfo" => page_info}}}} ->
        acc = acc ++ Enum.map(nodes, &to_item/1)

        if page_info["hasNextPage"] do
          paginate_items(owner, id, page_info["endCursor"], acc)
        else
          {:ok, acc}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_item(%{"content" => %{"__typename" => "Issue"} = content} = node) do
    %{
      type: :issue,
      number: content["number"],
      title: content["title"],
      body: content["body"],
      state: content["state"],
      url: content["url"],
      github_id: content["databaseId"],
      updated_at: content["updatedAt"],
      labels: content |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(& &1["name"]),
      author: get_in(content, ["author", "login"]),
      comments_count: get_in(content, ["comments", "totalCount"]) || 0,
      repo: get_in(content, ["repository", "nameWithOwner"]),
      assignees:
        content |> get_in(["assignees", "nodes"]) |> List.wrap() |> Enum.map(& &1["login"]),
      field_values: field_values(node)
    }
  end

  defp to_item(%{"content" => %{"__typename" => "PullRequest"} = content}) do
    %{type: :pull_request, number: content["number"]}
  end

  defp to_item(%{"content" => %{"__typename" => "DraftIssue"} = content}) do
    %{type: :draft_issue, title: content["title"]}
  end

  defp to_item(_node), do: %{type: :unknown}

  defp field_values(node) do
    node
    |> get_in(["fieldValues", "nodes"])
    |> List.wrap()
    |> Enum.map(fn field_value ->
      %{
        field: get_in(field_value, ["field", "name"]),
        value: field_value["name"] || field_value["text"]
      }
    end)
    |> Enum.reject(&is_nil(&1.field))
  end

  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp request(repo, method, path, opts \\ []) do
    pat_result =
      case repo do
        nil -> Harness.Secrets.github_pat()
        {:owner, owner} -> Harness.Secrets.github_pat_for_owner(owner)
        repo -> Harness.Secrets.github_pat(repo)
      end

    with {:ok, pat} <- pat_result do
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
