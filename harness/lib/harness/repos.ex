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
  def create_worktree!(repo, name), do: GenServer.call(__MODULE__, {:create_worktree, repo, name}, :infinity)

  @spec remove_worktree!(String.t(), Path.t()) :: :ok
  def remove_worktree!(repo, path), do: GenServer.call(__MODULE__, {:remove_worktree, repo, path}, :infinity)

  @doc "Shallow textual repo map for the triage prompt."
  @spec repo_map(String.t()) :: String.t()
  def repo_map(repo), do: GenServer.call(__MODULE__, {:repo_map, repo}, :infinity)

  @spec default_branch(String.t()) :: String.t()
  def default_branch(repo), do: GenServer.call(__MODULE__, {:default_branch, repo}, :infinity)

  @doc "Commit PLAN.md/CONTEXT.md in the worktree to `branch` and push it."
  @spec publish_branch!(String.t(), Path.t(), String.t(), [String.t()], String.t()) :: :ok
  def publish_branch!(repo, worktree, branch, files, message) do
    GenServer.call(__MODULE__, {:publish_branch, repo, worktree, branch, files, message}, :infinity)
  end

  # -- server -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{default_branches: %{}}}
  end

  @impl true
  def handle_call({:ensure_base, repo}, _from, state) do
    path = base_path(repo)

    if File.dir?(Path.join(path, ".git")) do
      git!(path, ["fetch", "origin", "--prune"], repo)
    else
      File.mkdir_p!(Path.dirname(path))
      git!(Path.dirname(path), ["clone", remote_url(repo), path], repo)
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
    git(worktree, ["branch", "-D", branch], repo)
    git!(worktree, ["checkout", "-b", branch], repo)
    git!(worktree, ["add" | files], repo)

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

    git!(worktree, ["push", "--force", "origin", branch], repo)
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
        raise "git #{Enum.join(scrub(args), " ")} (#{repo}) exited #{code}: #{String.trim(output)}"
    end
  end

  defp git(cd, args, _repo) do
    env =
      case Harness.Secrets.github_pat() do
        {:ok, pat} -> [{"GH_TOKEN", pat}]
        _ -> []
      end

    task =
      Task.async(fn ->
        System.cmd(
          "git",
          ["-c", "credential.helper=", "-c", "credential.helper=#{@credential_helper}" | args],
          cd: cd,
          env: env,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, @git_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, code}} -> {String.trim_trailing(output), code}
      nil -> {"git timed out after #{@git_timeout}ms", 124}
    end
  end

  defp scrub(args), do: args
end
