defmodule Harness.GitHub.ProvenanceTest do
  use ExUnit.Case, async: true

  alias Harness.GitHub.Provenance

  test "stamp → harness_authored? → parse round-trip" do
    stamped = Provenance.stamp("Hello!", "plan", "run-42")
    assert Provenance.harness_authored?(stamped)
    assert {:ok, %{version: "v1", kind: "plan", ref: "run-42"}} = Provenance.parse(stamped)
  end

  test "unmarked body returns false / :error" do
    refute Provenance.harness_authored?("Just a regular comment.")
    assert :error = Provenance.parse("Just a regular comment.")
  end

  test "marker is a valid HTML comment that renders to nothing" do
    stamped = Provenance.stamp("body", "pr", "run-99")
    marker = stamped |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "<!--"))
    assert marker =~ ~r/^<!-- harness:v1 kind=\S+ ref=\S+ -->$/
  end

  test "original body content is preserved" do
    body = "## Summary\n\nSome text."
    stamped = Provenance.stamp(body, "plan", "run-1")
    assert String.starts_with?(stamped, "## Summary")
    assert String.contains?(stamped, "Some text.")
  end
end
