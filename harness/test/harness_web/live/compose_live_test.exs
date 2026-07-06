defmodule HarnessWeb.ComposeLiveTest do
  use HarnessWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Harness.Fixtures

  alias Harness.Compose
  alias Harness.Runs

  @moduletag :capture_log

  setup do
    Application.put_env(:harness, :github_req_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

    on_exit(fn ->
      Application.delete_env(:harness, :github_req_options)
    end)

    :ok
  end

  # Swap in a policy that has one repo so the compose form is usable.
  defp with_policy_repo(ctx) do
    original = Application.fetch_env!(:harness, :policy_path)

    tmp =
      Path.join(System.tmp_dir!(), "compose-policy-#{System.unique_integer([:positive])}.yaml")

    File.write!(
      tmp,
      File.read!(original) |> String.replace("repos: []", "repos:\n  - owner/fixture")
    )

    Application.put_env(:harness, :policy_path, tmp)
    Harness.Policy.reload()

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      Harness.Policy.reload()
      File.rm(tmp)
    end)

    Map.put(ctx, :repo, "owner/fixture")
  end

  test "empty state shows compose form and empty drafts list", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/compose")
    assert html =~ "New draft"
    assert html =~ "No drafts yet"
    assert html =~ "Explore"
  end

  test "renders the styled attachment dropzone instead of a bare file input", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/compose")

    assert html =~ "attachments-dropzone"
    assert html =~ "Drop files, click to browse, or paste an image"
    assert html =~ ~s(phx-hook="HarnessWeb.CoreComponents.PasteUpload")
  end

  test "submit with blank prompt shows error flash", %{conn: conn} do
    ctx = with_policy_repo(%{})
    {:ok, view, _html} = live(conn, ~p"/compose")

    html =
      view
      |> form("form", %{"prompt" => "   ", "repo" => ctx.repo})
      |> render_submit()

    assert html =~ "Describe your idea first"
    refute_push_event(view, "clear_draft", %{})
  end

  test "submit with no repo shows error flash and does not clear persisted draft", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/compose")

    html =
      view
      |> form("form", %{"prompt" => "An idea", "repo" => ""})
      |> render_submit()

    assert html =~ "Select a policy repo"
    refute_push_event(view, "clear_draft", %{})
  end

  test "successful submit clears the persisted draft", %{conn: conn} do
    ctx = with_policy_repo(%{})
    {:ok, view, _html} = live(conn, ~p"/compose")

    view
    |> form("form", %{"prompt" => "An idea", "repo" => ctx.repo})
    |> render_submit()

    assert_push_event(view, "clear_draft", %{key: "compose:new-draft"})
  end

  test "approve with stubbed client → draft approved, success flash shown", %{conn: conn} do
    ctx = with_policy_repo(%{})

    # Stub viewer_login → 200, create_issue → 201
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/user" ->
          Req.Test.json(conn, %{"login" => "testuser"})

        "/repos/" <> _ ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "number" => 99,
            "html_url" => "https://github.com/owner/fixture/issues/99"
          })

        _ ->
          Plug.Conn.send_resp(conn, 500, "")
      end
    end)

    draft =
      draft_fixture(%{
        repo: ctx.repo,
        title: "Speed up widget",
        body:
          "## Problem\n\nSlow.\n\n## Change\n\nFix it.\n\n## Acceptance\n\n- Fast.\n\n## Non-goals\n\nNone."
      })

    {:ok, view, _html} = live(conn, ~p"/compose/#{draft.id}")

    html =
      view
      |> element("button", "Approve")
      |> render_click()

    assert html =~ "filed"
    assert Compose.get_draft!(draft.id).status == "approved"
  end

  test "draft with a body shows a download link independent of filing status", %{conn: conn} do
    draft =
      draft_fixture(%{
        title: "Speed up widget",
        body: "## Problem\n\nSlow."
      })

    {:ok, _view, html} = live(conn, ~p"/compose/#{draft.id}")
    assert html =~ ~s(href="/compose/#{draft.id}/draft.md")
  end

  test "discard → draft status discarded, never touches GitHub client", %{conn: conn} do
    ctx = with_policy_repo(%{})

    draft =
      draft_fixture(%{
        repo: ctx.repo,
        title: "An idea",
        body:
          "## Problem\n\nX.\n\n## Change\n\nY.\n\n## Acceptance\n\n- Z.\n\n## Non-goals\n\nNone."
      })

    # If GitHub were called, the stub returns 500 → test would surface an error
    {:ok, view, _html} = live(conn, ~p"/compose/#{draft.id}")
    view |> element("button", "Discard") |> render_click()

    assert Compose.get_draft!(draft.id).status == "discarded"
  end

  test "exploring spinner shown for draft with queued run", %{conn: conn} do
    ctx = with_policy_repo(%{})
    draft = draft_fixture(%{repo: ctx.repo})

    run =
      Runs.create_run!(%{
        kind: "explore",
        model: "sonnet",
        status: "running",
        ref: "compose/draft-#{draft.id}"
      })

    Compose.update_draft!(draft, %{run_id: run.id})

    {:ok, _view, html} = live(conn, ~p"/compose/#{draft.id}")
    assert html =~ "exploring"
  end

  test "failed explore shows error badge with run error", %{conn: conn} do
    ctx = with_policy_repo(%{})
    draft = draft_fixture(%{repo: ctx.repo})

    run =
      Runs.create_run!(%{
        kind: "explore",
        model: "sonnet",
        status: "failed",
        error: "timed out after 20 turns",
        ref: "compose/draft-#{draft.id}"
      })

    Compose.update_draft!(draft, %{run_id: run.id})

    {:ok, _view, html} = live(conn, ~p"/compose/#{draft.id}")
    assert html =~ "explore failed"
    assert html =~ "timed out after 20 turns"
  end

  test "PAT scope error renders actionable flash", %{conn: conn} do
    ctx = with_policy_repo(%{})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/user" ->
          Req.Test.json(conn, %{"login" => "testuser"})

        "/repos/" <> _ ->
          conn
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(%{"message" => "Forbidden"})

        _ ->
          Plug.Conn.send_resp(conn, 500, "")
      end
    end)

    draft =
      draft_fixture(%{
        repo: ctx.repo,
        title: "An idea",
        body:
          "## Problem\n\nX.\n\n## Change\n\nY.\n\n## Acceptance\n\n- Z.\n\n## Non-goals\n\nNone."
      })

    {:ok, view, _html} = live(conn, ~p"/compose/#{draft.id}")

    html =
      view
      |> element("button", "Approve")
      |> render_click()

    assert html =~ "PAT" or html =~ "GitHub error"
  end
end
