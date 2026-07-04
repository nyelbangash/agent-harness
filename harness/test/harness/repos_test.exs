defmodule Harness.ReposTest do
  # async: false — global :github_remote_base + shared Repos GenServer
  use ExUnit.Case, async: false

  import Harness.Fixtures, only: [create_git_remote!: 2]

  alias Harness.Repos

  setup do
    tmp = Path.join(System.tmp_dir!(), "repos-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = "owner/rt#{System.unique_integer([:positive])}"
    bare = create_git_remote!(tmp, repo)
    Application.put_env(:harness, :github_remote_base, "file://#{tmp}/")

    on_exit(fn ->
      Application.delete_env(:harness, :github_remote_base)
      File.rm_rf!(tmp)
    end)

    %{repo: repo, bare: bare}
  end

  test "ensure_base! clones once and fetches thereafter", %{repo: repo} do
    path = Repos.ensure_base!(repo)
    assert File.dir?(Path.join(path, ".git"))
    assert File.exists?(Path.join(path, "README.md"))

    # second call fetches into the same clone
    assert Repos.ensure_base!(repo) == path
  end

  test "default_branch resolves from the remote", %{repo: repo} do
    Repos.ensure_base!(repo)
    assert Repos.default_branch(repo) == "main"
  end

  test "worktrees are created at the default tip and removed cleanly", %{repo: repo} do
    Repos.ensure_base!(repo)
    wt = Repos.create_worktree!(repo, "test-wt-#{System.unique_integer([:positive])}")

    assert File.exists?(Path.join(wt, "src/widget.ex"))
    assert wt |> Path.dirname() |> String.ends_with?("test_workspaces")

    assert :ok = Repos.remove_worktree!(repo, wt)
    refute File.exists?(wt)
  end

  test "repo_map summarizes the tree and includes CLAUDE.md", %{repo: repo} do
    Repos.ensure_base!(repo)
    map = Repos.repo_map(repo)

    assert map =~ "src/ — 1 files"
    assert map =~ "src/widget.ex"
    assert map =~ "CLAUDE.md"
    assert map =~ "mix test"
  end

  test "publish_branch! commits chosen files and pushes to the remote", %{repo: repo, bare: bare} do
    Repos.ensure_base!(repo)
    wt = Repos.create_worktree!(repo, "publish-wt-#{System.unique_integer([:positive])}")

    File.write!(Path.join(wt, "PLAN.md"), "# The plan\n")
    File.write!(Path.join(wt, "CONTEXT.md"), "# The context\n")
    File.write!(Path.join(wt, "scratch.tmp"), "should not be committed")

    assert :ok =
             Repos.publish_branch!(
               repo,
               wt,
               "harness/plans/issue-1",
               ["PLAN.md", "CONTEXT.md"],
               "Plan packet"
             )

    {refs, 0} =
      System.cmd("git", ["ls-remote", "file://#{bare}", "refs/heads/harness/plans/issue-1"])

    assert refs =~ "harness/plans/issue-1"

    {files, 0} = System.cmd("git", ["ls-tree", "--name-only", "harness/plans/issue-1"], cd: bare)
    assert files =~ "PLAN.md"
    assert files =~ "CONTEXT.md"
    refute files =~ "scratch.tmp"

    Repos.remove_worktree!(repo, wt)
  end

  test "publish_branch! refuses non-harness branches and the default branch (§9.2)", %{repo: repo} do
    Repos.ensure_base!(repo)
    wt = Repos.create_worktree!(repo, "guard-wt-#{System.unique_integer([:positive])}")
    File.write!(Path.join(wt, "PLAN.md"), "x")

    assert_raise RuntimeError, ~r/refusing to push/, fn ->
      Repos.publish_branch!(repo, wt, "main", ["PLAN.md"], "nope")
    end

    assert_raise RuntimeError, ~r/refusing to push/, fn ->
      Repos.publish_branch!(repo, wt, "feature/sneaky", ["PLAN.md"], "nope")
    end

    Repos.remove_worktree!(repo, wt)
  end

  test "ensure_base! refreshes the working tree to the remote tip", %{repo: repo, bare: bare} do
    path = Repos.ensure_base!(repo)
    refute File.exists?(Path.join(path, "NEW.md"))

    # push a new commit to the remote from a scratch clone
    scratch = Path.join(System.tmp_dir!(), "scratch-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", "-q", "file://#{bare}", scratch])
    File.write!(Path.join(scratch, "NEW.md"), "fresh content")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: scratch)

    {_, 0} =
      System.cmd("git", ~w(-c user.name=t -c user.email=t@t commit -q -m update), cd: scratch)

    {_, 0} = System.cmd("git", ["push", "-q"], cd: scratch)
    File.rm_rf!(scratch)

    # a fresh ensure_base! must surface the new file in the working tree
    Repos.ensure_base!(repo)
    assert File.exists?(Path.join(path, "NEW.md"))
  end
end
