defmodule Harness.ReposTest do
  # async: false — global :github_remote_base + shared Repos GenServer
  use ExUnit.Case, async: false

  import Harness.Fixtures, only: [create_git_remote!: 2]

  alias Harness.Repos

  defp git!(cd, args) do
    {output, code} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    if code != 0, do: raise("fixture git #{Enum.join(args, " ")} failed: #{output}")
    output
  end

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

  test "ensure_base! rebuilds a clone whose origin is not the configured remote", %{
    repo: repo,
    bare: bare
  } do
    path = Repos.ensure_base!(repo)

    # the shape a clone left by an earlier test run has: its file:// remote
    # was deleted, and :github_remote_base now points at a fresh fixture that
    # happens to reuse the same repo name
    File.rm_rf!(bare)
    tmp2 = Path.join(System.tmp_dir!(), "repos-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp2)
    create_git_remote!(tmp2, repo)
    Application.put_env(:harness, :github_remote_base, "file://#{tmp2}/")
    on_exit(fn -> File.rm_rf!(tmp2) end)

    assert Repos.ensure_base!(repo) == path
    {url, 0} = System.cmd("git", ["-C", path, "remote", "get-url", "origin"])
    assert String.trim(url) == "file://#{tmp2}/#{repo}.git"
  end

  test "rebase_onto! succeeds when there are no conflicts", %{repo: repo, bare: bare} do
    Repos.ensure_base!(repo)

    # Create a branch with a new file (no conflict with main)
    branch = "harness/rebase-clean-#{System.unique_integer([:positive])}"
    seed = bare <> "-seed-#{System.unique_integer([:positive])}"
    File.mkdir_p!(seed)
    git!(seed, ["clone", "file://" <> bare, seed])
    git!(seed, ["checkout", "-b", branch])
    File.write!(Path.join(seed, "branch_only.txt"), "branch content")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "branch commit"])
    git!(seed, ["push", "origin", branch])
    File.rm_rf!(seed)

    worktree =
      Repos.create_worktree_at!(
        repo,
        "rebase-clean-wt-#{System.unique_integer([:positive])}",
        "origin/#{branch}"
      )

    assert :ok = Repos.rebase_onto!(repo, worktree, "main")
    Repos.remove_worktree!(repo, worktree)
  end

  test "rebase_onto! returns {:conflict, files} on conflict", %{repo: repo, bare: bare} do
    Repos.ensure_base!(repo)

    # Create a branch that modifies the same file as we'll modify on main
    branch = "harness/rebase-conflict-#{System.unique_integer([:positive])}"
    seed = bare <> "-seed-#{System.unique_integer([:positive])}"
    File.mkdir_p!(seed)
    git!(seed, ["clone", "file://" <> bare, seed])

    # First commit a change on main (to make branch diverge)
    File.write!(Path.join(seed, "conflict_file.txt"), "main content\n")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main adds file"])
    git!(seed, ["push", "origin", "main"])

    # Now make the branch starting before that main commit
    git!(seed, ["checkout", "HEAD~1"])
    git!(seed, ["checkout", "-b", branch])
    File.write!(Path.join(seed, "conflict_file.txt"), "branch content\n")
    git!(seed, ["add", "-A"])

    git!(seed, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "commit",
      "-m",
      "branch adds same file"
    ])

    git!(seed, ["push", "origin", branch])
    File.rm_rf!(seed)

    worktree =
      Repos.create_worktree_at!(
        repo,
        "rebase-conflict-wt-#{System.unique_integer([:positive])}",
        "origin/#{branch}"
      )

    assert {:conflict, files} = Repos.rebase_onto!(repo, worktree, "main")
    assert "conflict_file.txt" in files
    # Clean up rebase state
    Repos.rebase_abort!(repo, worktree)
    Repos.remove_worktree!(repo, worktree)
  end

  test "rebase_abort! cleans up after a failed rebase", %{repo: repo, bare: bare} do
    Repos.ensure_base!(repo)

    branch = "harness/abort-test-#{System.unique_integer([:positive])}"
    seed = bare <> "-seed-#{System.unique_integer([:positive])}"
    File.mkdir_p!(seed)
    git!(seed, ["clone", "file://" <> bare, seed])

    File.write!(Path.join(seed, "shared.txt"), "main version\n")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main"])
    git!(seed, ["push", "origin", "main"])

    git!(seed, ["checkout", "HEAD~1"])
    git!(seed, ["checkout", "-b", branch])
    File.write!(Path.join(seed, "shared.txt"), "branch version\n")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "branch"])
    git!(seed, ["push", "origin", branch])
    File.rm_rf!(seed)

    worktree =
      Repos.create_worktree_at!(
        repo,
        "abort-wt-#{System.unique_integer([:positive])}",
        "origin/#{branch}"
      )

    assert {:conflict, _} = Repos.rebase_onto!(repo, worktree, "main")
    assert :ok = Repos.rebase_abort!(repo, worktree)

    # After abort, git status should be clean (no merge/rebase in progress)
    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: worktree)
    assert String.trim(status) == ""
    Repos.remove_worktree!(repo, worktree)
  end

  test "rebase_continue! resolves after manual fix", %{repo: repo, bare: bare} do
    Repos.ensure_base!(repo)

    branch = "harness/continue-test-#{System.unique_integer([:positive])}"
    seed = bare <> "-seed-#{System.unique_integer([:positive])}"
    File.mkdir_p!(seed)
    git!(seed, ["clone", "file://" <> bare, seed])

    File.write!(Path.join(seed, "resolve_me.txt"), "main version\n")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main"])
    git!(seed, ["push", "origin", "main"])

    git!(seed, ["checkout", "HEAD~1"])
    git!(seed, ["checkout", "-b", branch])
    File.write!(Path.join(seed, "resolve_me.txt"), "branch version\n")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "branch"])
    git!(seed, ["push", "origin", branch])
    File.rm_rf!(seed)

    worktree =
      Repos.create_worktree_at!(
        repo,
        "continue-wt-#{System.unique_integer([:positive])}",
        "origin/#{branch}"
      )

    assert {:conflict, _} = Repos.rebase_onto!(repo, worktree, "main")

    # Manually resolve the conflict
    File.write!(Path.join(worktree, "resolve_me.txt"), "resolved content\n")

    assert :ok = Repos.rebase_continue!(repo, worktree)
    Repos.remove_worktree!(repo, worktree)
  end

  test "force_push_head! pushes to remote and is visible via ls-remote", %{repo: repo, bare: bare} do
    Repos.ensure_base!(repo)

    branch = "harness/force-push-#{System.unique_integer([:positive])}"
    seed = bare <> "-seed-#{System.unique_integer([:positive])}"
    File.mkdir_p!(seed)
    git!(seed, ["clone", "file://" <> bare, seed])
    git!(seed, ["checkout", "-b", branch])
    File.write!(Path.join(seed, "pushed.txt"), "force pushed")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "force push test"])
    git!(seed, ["push", "origin", branch])
    File.rm_rf!(seed)

    worktree =
      Repos.create_worktree_at!(
        repo,
        "force-push-wt-#{System.unique_integer([:positive])}",
        "origin/#{branch}"
      )

    # Add a new commit in the worktree
    File.write!(Path.join(worktree, "extra.txt"), "extra")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: worktree)

    {_, 0} =
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "extra"],
        cd: worktree
      )

    assert :ok = Repos.force_push_head!(repo, worktree, branch)

    {refs, 0} = System.cmd("git", ["ls-remote", "file://#{bare}", "refs/heads/#{branch}"])
    assert refs =~ branch

    Repos.remove_worktree!(repo, worktree)
  end

  test "force_push_head! raises on non-harness branch", %{repo: repo} do
    Repos.ensure_base!(repo)
    wt = Repos.create_worktree!(repo, "guard-fp-wt-#{System.unique_integer([:positive])}")

    assert_raise RuntimeError, ~r/refusing to force-push/, fn ->
      Repos.force_push_head!(repo, wt, "feature/human-authored")
    end

    Repos.remove_worktree!(repo, wt)
  end

  test "force_push_head! returns {:error, :lease_broken} when remote moved", %{
    repo: repo,
    bare: bare
  } do
    Repos.ensure_base!(repo)

    branch = "harness/lease-test-#{System.unique_integer([:positive])}"
    seed = bare <> "-seed-#{System.unique_integer([:positive])}"
    File.mkdir_p!(seed)
    git!(seed, ["clone", "file://" <> bare, seed])
    git!(seed, ["checkout", "-b", branch])
    File.write!(Path.join(seed, "initial.txt"), "initial")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "initial"])
    git!(seed, ["push", "origin", branch])

    # Create the worktree now (tracking the initial commit A)
    worktree =
      Repos.create_worktree_at!(
        repo,
        "lease-wt-#{System.unique_integer([:positive])}",
        "origin/#{branch}"
      )

    # After the worktree is created, the remote advances (breaking the lease)
    File.write!(Path.join(seed, "remote_advance.txt"), "advanced")
    git!(seed, ["add", "-A"])
    git!(seed, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "remote advance"])
    git!(seed, ["push", "origin", branch])
    File.rm_rf!(seed)

    # Add a local commit in the worktree that diverges from the now-advanced remote
    File.write!(Path.join(worktree, "local.txt"), "local change")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: worktree)

    {_, 0} =
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "local"],
        cd: worktree
      )

    # The remote has advanced past our tracking ref so --force-with-lease should fail
    assert {:error, :lease_broken} = Repos.force_push_head!(repo, worktree, branch)

    Repos.remove_worktree!(repo, worktree)
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

  test "ensure_base! resolves the git credential via the repo's owner", %{repo: repo} do
    # the fixture remote is file:// (no credential helper round-trip to
    # assert against), so this stubs Secrets.github_pat/1 for the repo's
    # owner and asserts the git operation still succeeds — i.e. `git/4`
    # resolved (and didn't choke on) a per-owner credential rather than the
    # single global one.
    owner = Harness.Secrets.owner_of(repo)
    Application.put_env(:harness, :github_pat_overrides, %{owner => "owner-scoped-pat"})
    on_exit(fn -> Application.delete_env(:harness, :github_pat_overrides) end)

    path = Repos.ensure_base!(repo)
    assert File.dir?(Path.join(path, ".git"))
  end
end
