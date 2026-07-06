defmodule Harness.BuildInfo do
  @moduledoc """
  The git SHA of the code this module was compiled from.

  `@external_resource` on the git HEAD (and the ref it points at) makes the
  dev code reloader recompile this module whenever the checkout moves — so
  `code_sha/0` stays truthful under hot reloads, not just full boots. Without
  this, the stale-code lamp reads red forever in the no-restart era: hot
  reloads update every changed module EXCEPT the one holding the SHA.
  """

  git_dir = Path.expand("../../../.git", __DIR__)

  @external_resource Path.join(git_dir, "HEAD")

  head = Path.join(git_dir, "HEAD") |> File.read!() |> String.trim()

  with "ref: " <> ref <- head,
       ref_path = Path.join(git_dir, ref),
       true <- File.exists?(ref_path) do
    @external_resource ref_path
  end

  @sha System.cmd("git", ["rev-parse", "--short", "HEAD"]) |> elem(0) |> String.trim()
  def code_sha, do: @sha
end
