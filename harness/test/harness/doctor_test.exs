defmodule Harness.DoctorTest do
  # async: false — swaps the global :policy_path
  use ExUnit.Case, async: false

  alias Harness.Doctor

  defp github_api_check_ids do
    Doctor.checks()
    |> Enum.map(& &1.id)
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "github_api_"))
  end

  test "renders one github_api check per owner configured in ops/policy.yaml" do
    original = Application.fetch_env!(:harness, :policy_path)
    tmp = Path.join(System.tmp_dir!(), "doctor-policy-#{System.unique_integer([:positive])}.yaml")

    File.write!(
      tmp,
      File.read!(original)
      |> String.replace(~r/repos:.*/, ~s(repos: ["acme/one", "acme/two", "globex/three"]))
    )

    Application.put_env(:harness, :policy_path, tmp)

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      File.rm(tmp)
    end)

    ids = github_api_check_ids()
    assert :github_api_acme in ids
    assert :github_api_globex in ids
    assert length(ids) == 2

    labels = Doctor.checks() |> Enum.map(& &1.label)
    assert "GitHub API reachable (acme)" in labels
    assert "GitHub API reachable (globex)" in labels
  end

  test "falls back to a single sentinel owner when no repos are configured" do
    original = Application.fetch_env!(:harness, :policy_path)
    tmp = Path.join(System.tmp_dir!(), "doctor-policy-#{System.unique_integer([:positive])}.yaml")

    File.write!(tmp, File.read!(original) |> String.replace(~r/repos:.*/, "repos: []"))
    Application.put_env(:harness, :policy_path, tmp)

    on_exit(fn ->
      Application.put_env(:harness, :policy_path, original)
      File.rm(tmp)
    end)

    assert github_api_check_ids() == [:github_api_default]
  end
end
