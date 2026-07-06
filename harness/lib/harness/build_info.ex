defmodule Harness.BuildInfo do
  @moduledoc """
  The git SHA of the code this module was compiled from.

  `@external_resource` on the git HEAD (and the ref it points at) makes the
  dev code reloader recompile this module whenever the checkout moves — so
  `code_sha/0` stays truthful under hot reloads, not just full boots. Without
  this, the stale-code lamp reads red forever in the no-restart era: hot
  reloads update every changed module EXCEPT the one holding the SHA.
  """

  dot_git = Path.expand("../../../.git", __DIR__)

  # In a linked worktree, `.git` is a file ("gitdir: <path>") rather than a
  # directory, and its per-worktree HEAD/refs live under that path while
  # branch refs are shared via a `commondir` pointing back at the main repo.
  git_dir =
    case File.read(dot_git) do
      {:ok, "gitdir: " <> gitdir} -> gitdir |> String.trim() |> Path.expand(Path.dirname(dot_git))
      _ -> dot_git
    end

  common_dir =
    case File.read(Path.join(git_dir, "commondir")) do
      {:ok, dir} -> dir |> String.trim() |> Path.expand(git_dir)
      _ -> git_dir
    end

  @external_resource Path.join(git_dir, "HEAD")

  head = Path.join(git_dir, "HEAD") |> File.read!() |> String.trim()

  with "ref: " <> ref <- head,
       ref_path = Path.join(common_dir, ref),
       true <- File.exists?(ref_path) do
    @external_resource ref_path
  end

  @sha System.cmd("git", ["rev-parse", "--short", "HEAD"]) |> elem(0) |> String.trim()
  def code_sha, do: @sha
end
