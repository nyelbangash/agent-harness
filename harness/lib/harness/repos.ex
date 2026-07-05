defmodule Harness.Repos do
  @moduledoc """
  Base-clone manager. Keeps one clone per target repo under
  `~/.harness/repos/{owner}--{name}` and hands out throwaway git worktrees
  under `workspaces/` for runs. A single GenServer serializes git operations —
  worktree add/remove on the same clone is not concurrency-safe, and this is
  a single-user system.

  Authentication: the PAT is injected per-command through an ephemeral
  credential helper (`username=x-access-token`, password from the command's
  own environment). It never appears in remote URLs, `.git/config`, or argv.
  """

  use GenServer
  require Logger

  @credential_helper "!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f"
  @git_timeout :timer.minutes(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Clone (or fetch) the base clone. Returns its path."
  @spec ensure_base!(String.t()) :: Path.t()
  def ensure_base!(repo), do: GenServer.call(__MODULE__, {:ensure_base, repo}, :infinity)

  @doc "Fresh detached worktree at the default branch tip, under workspaces/."
  @spec create_worktree!(String.t(), String.t()) :: Path.t()
  def create_worktree!(repo, name),
    do: GenServer.call(__MODULE__, {:create_worktree, repo, name}, :infinity)

  @doc "Fresh detached worktree at an explicit ref (e.g. \"origin/harness/issue-5-…\")."
  @spec create_worktree_at!(String.t(), String.t(), String.t()) :: Path.t()
  def create_worktree_at!(repo, name, ref),
    do: GenServer.call(__MODULE__, {:create_worktree_at, repo, name, ref}, :infinity)

  @spec remove_worktree!(String.t(), Path.t()) :: :ok
  def remove_worktree!(repo, path),
    do: GenServer.call(__MODULE__, {:remove_worktree, repo, path}, :infinity)

  @doc "Shallow textual repo map for the triage prompt."
  @spec repo_map(String.t()) :: String.t()
  def repo_map(repo), do: GenServer.call(__MODULE__, {:repo_map, repo}, :infinity)

  @spec default_branch(String.t()) :: String.t()
  def default_branch(repo), do: GenServer.call(__MODULE__, {:default_branch, repo}, :infinity)

  @doc "Paths the agent touched in the worktree (for the PR body)."
  @spec changed_files(Path.t()) :: [String.t()]
  def changed_files(worktree) do
    # -uall lists individual untracked files rather than collapsing dirs
    case System.cmd("git", ["-C", worktree, "status", "--porcelain", "-uall"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.slice(3..-1//1) |> String.trim()))
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  @doc """
  Commit PLAN.md/CONTEXT.md in the worktree to `branch` and push it.

  Spec §9.2 pre-push guard (non-negotiable): only `harness/*` branches may
  ever be pushed, and never the repo's default branch.
  """
  @spec publish_branch!(String.t(), Path.t(), String.t(), [String.t()] | :all, String.t()) :: :ok
  def publish_branch!(repo, worktree, branch, files, message) do
    unless String.starts_with?(branch, "harness/") and branch != default_branch(repo) do
      raise "refusing to push #{inspect(branch)} — only harness/* branches may be pushed (§9.2)"
    end

    GenServer.call(
      __MODULE__,
      {:publish_branch, repo, worktree, branch, files, message},
      :infinity
    )
  end

  # -- server -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{default_branches: %{}}}
  end

  @impl true
  def handle_call({:ensure_base, repo}, _from, state) do
    path = base_path(repo)

    state =
      if reusable_clone?(path, repo) do
        git!(path, ["fetch", "origin", "--prune"], repo)
        # fetch only updates remote refs — refresh the checked-out tree too,
        # or triage sessions read a snapshot from the day of the first clone
        {branch, state} = fetch_default_branch(repo, state)
        git!(path, ["reset", "--hard", "origin/#{branch}"], repo)
        state
      else
        # missing, half-cloned, or tracking a different remote — rebuild
        # rather than fetch from the wrong place
        File.rm_rf!(path)
        File.mkdir_p!(Path.dirname(path))
        git!(Path.dirname(path), ["clone", remote_url(repo), path], repo)
        # a default branch learned from the old remote doesn't carry over
        %{state | default_branches: Map.delete(state.default_branches, repo)}
      end

    {:reply, path, state}
  end

  def handle_call({:create_worktree, repo, name}, _from, state) do
    base = base_path(repo)
    {branch, state} = fetch_default_branch(repo, state)
    wt = Path.join(Application.fetch_env!(:harness, :workspaces_dir), name)

    if File.exists?(wt), do: git(base, ["worktree", "remove", "--force", wt], repo)
    git!(base, ["worktree", "add", "--detach", wt, "origin/#{branch}"], repo)

    {:reply, wt, state}
  end

  def handle_call({:create_worktree_at, repo, name, ref}, _from, state) do
    base = base_path(repo)
    branch = String.replace_prefix(ref, "origin/", "")
    git(base, ["fetch", "origin", branch], repo)
    wt = Path.join(Application.fetch_env!(:harness, :workspaces_dir), name)
    if File.exists?(wt), do: git(base, ["worktree", "remove", "--force", wt], repo)
    git!(base, ["worktree", "add", "--detach", wt, ref], repo)
    {:reply, wt, state}
  end

  def handle_call({:remove_worktree, repo, path}, _from, state) do
    base = base_path(repo)
    git(base, ["worktree", "remove", "--force", path], repo)
    git(base, ["worktree", "prune"], repo)
    if File.exists?(path), do: File.rm_rf!(path)
    {:reply, :ok, state}
  end

  def handle_call({:repo_map, repo}, _from, state) do
    base = base_path(repo)
    {files, 0} = git(base, ["ls-files"], repo)
    file_list = String.split(files, "\n", trim: true)

    dirs =
      file_list
      |> Enum.group_by(fn path ->
        case Path.split(path) do
          [_file] -> "(root)"
          [dir | _] -> dir
        end
      end)
      |> Enum.map(fn {dir, entries} -> "#{dir}/ — #{length(entries)} files" end)
      |> Enum.sort()

    head_doc =
      Enum.find_value(["CLAUDE.md", "README.md", "readme.md"], "", fn doc ->
        doc_path = Path.join(base, doc)

        if File.exists?(doc_path) do
          head =
            doc_path
            |> File.stream!()
            |> Enum.take(30)
            |> Enum.join()

          "\n## #{doc} (first 30 lines)\n#{head}"
        end
      end)

    map = """
    Total files: #{length(file_list)}
    #{Enum.join(dirs, "\n")}

    ## Sample paths
    #{file_list |> Enum.take(120) |> Enum.join("\n")}
    #{head_doc}
    """

    {:reply, map, state}
  end

  def handle_call({:default_branch, repo}, _from, state) do
    {branch, state} = fetch_default_branch(repo, state)
    {:reply, branch, state}
  end

  def handle_call({:publish_branch, repo, worktree, branch, files, message}, _from, state) do
    # defense in depth for the §9.2 guard already enforced in the client fn
    true = String.starts_with?(branch, "harness/")

    git(worktree, ["branch", "-D", branch], repo)
    git!(worktree, ["checkout", "-b", branch], repo)

    case files do
      :all -> git!(worktree, ["add", "-A"], repo)
      list when is_list(list) -> git!(worktree, ["add" | list], repo)
    end

    git!(
      worktree,
      [
        "-c",
        "user.name=harness",
        "-c",
        "user.email=harness@users.noreply.github.com",
        "commit",
        "-m",
        message
      ],
      repo
    )

    # --force-with-lease, not --force: if commits were layered onto an
    # earlier harness branch (e.g. a human pushed a fixup), the push fails
    # loudly rather than silently clobbering them
    git!(worktree, ["push", "--force-with-lease", "origin", branch], repo)
    {:reply, :ok, state}
  end

  # -- internals ------------------------------------------------------------------

  defp fetch_default_branch(repo, state) do
    case state.default_branches do
      %{^repo => branch} ->
        {branch, state}

      _ ->
        base = base_path(repo)
        git(base, ["remote", "set-head", "origin", "--auto"], repo)

        branch =
          case git(base, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], repo) do
            {"origin/" <> branch, 0} -> String.trim(branch)
            _ -> "main"
          end

        {branch, put_in(state.default_branches[repo], branch)}
    end
  end

  # A clone is only reusable if it tracks the remote we would clone from
  # today: `:github_remote_base` is configurable, so a clone made under an
  # earlier configuration must be rebuilt, not fetched.
  defp reusable_clone?(path, repo) do
    with true <- File.dir?(Path.join(path, ".git")),
         {url, 0} <- git(path, ["remote", "get-url", "origin"], repo) do
      String.trim(url) == remote_url(repo)
    else
      _ -> false
    end
  end

  defp base_path(repo) do
    home = Application.fetch_env!(:harness, :harness_home)
    Path.join([home, "repos", String.replace(repo, "/", "--")])
  end

  defp remote_url(repo) do
    base = Application.get_env(:harness, :github_remote_base, "https://github.com/")
    base <> repo <> ".git"
  end

  defp git!(cd, args, repo) do
    case git(cd, args, repo) do
      {output, 0} ->
        output

      {output, code} ->
        raise "git #{Enum.join(args, " ")} (#{repo}) exited #{code}: #{String.trim(output)}"
    end
  end

  # Port-based runner (not System.cmd-in-Task): on timeout the git OS process
  # must actually be signaled — killing only the BEAM task would leak a live
  # git holding locks on the clone, silently breaking this GenServer's
  # single-writer guarantee when the Oban retry runs a second git against it.
  defp git(cd, args, _repo) do
    env =
      case Harness.Secrets.github_pat() do
        {:ok, pat} -> [{~c"GH_TOKEN", String.to_charlist(pat)}]
        _ -> []
      end

    git_path = System.find_executable("git")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-c",
          ~s(exec "$0" "$@" < /dev/null),
          git_path,
          "-c",
          "credential.helper=",
          "-c",
          "credential.helper=#{@credential_helper}" | args
        ],
        cd: cd,
        env: env
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    collect_port(port, os_pid, "", System.monotonic_time(:millisecond) + @git_timeout)
  end

  defp collect_port(port, os_pid, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        collect_port(port, os_pid, acc <> chunk, deadline)

      {^port, {:exit_status, code}} ->
        {String.trim_trailing(acc), code}
    after
      remaining ->
        if is_integer(os_pid) do
          System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
          Process.sleep(2_000)
          System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        end

        # drain whatever the dying process flushes, then close
        result =
          receive do
            {^port, {:exit_status, _}} -> :ok
          after
            3_000 -> Port.close(port)
          end

        _ = result
        {"git timed out after #{@git_timeout}ms (process killed)", 124}
    end
  end
end
