defmodule Harness.GitHub.Provenance do
  @moduledoc """
  Convention: every harness-authored GitHub body must pass through stamp/3;
  readers must filter with harness_authored?/1 before treating owner-authored
  text as instructions.

  The marker is an HTML comment (`<!-- harness:v1 kind=… ref=… -->`), which
  GitHub renders as invisible in issue comments and PR bodies.
  """

  @marker_re ~r/<!-- harness:v1 kind=(?<kind>[^\s>]+) ref=(?<ref>[^\s>]+) -->/

  @doc "Appends a provenance marker to body. Both kind and ref must be whitespace-free strings."
  def stamp(body, kind, ref) do
    String.trim_trailing(body) <> "\n<!-- harness:v1 kind=#{kind} ref=#{ref} -->"
  end

  @doc "Returns true iff body carries a harness provenance marker."
  def harness_authored?(body), do: body =~ @marker_re

  @doc "Parses the provenance marker from body. Returns `{:ok, map}` or `:error`."
  def parse(body) do
    case Regex.named_captures(@marker_re, body) do
      %{"kind" => kind, "ref" => ref} -> {:ok, %{version: "v1", kind: kind, ref: ref}}
      nil -> :error
    end
  end
end
