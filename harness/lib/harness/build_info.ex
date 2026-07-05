defmodule Harness.BuildInfo do
  @sha System.cmd("git", ["rev-parse", "--short", "HEAD"]) |> elem(0) |> String.trim()
  def code_sha, do: @sha
end
