defmodule Harness.Fixtures do
  @moduledoc "Shared test fixtures: issues, GitHub payloads, local git remotes."

  alias Harness.GitHub.Issue
  alias Harness.Repo

  def issue_fixture(attrs \\ %{}) do
    defaults = %{
      repo: "owner/fixture",
      number: System.unique_integer([:positive]),
      github_id: System.unique_integer([:positive]),
      title: "Fix the widget",
      body: "The widget is broken in src/widget.ex",
      state: "open",
      labels: [],
      author: "someone",
      url: "https://github.com/owner/fixture/issues/1",
      github_updated_at: DateTime.utc_now(),
      pipeline_state: "incoming"
    }

    %Issue{} |> Issue.changeset(Map.merge(defaults, attrs)) |> Repo.insert!()
  end

  def gh_issue_payload(attrs \\ %{}) do
    number = attrs[:number] || System.unique_integer([:positive])

    Map.merge(
      %{
        "id" => System.unique_integer([:positive]),
        "number" => number,
        "title" => "Fix the widget",
        "body" => "The widget is broken",
        "state" => "open",
        "labels" => [],
        "user" => %{"login" => "someone"},
        "html_url" => "https://github.com/owner/fixture/issues/#{number}",
        "comments" => 0,
        "updated_at" => "2026-07-04T12:00:00Z"
      },
      Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    )
  end

  def triage_output(attrs \\ %{}) do
    Map.merge(
      %{
        "route" => "plan",
        "confidence" => 0.8,
        "reasoning" => "multi-file change",
        "estimated_scope" => "m",
        "risk_flags" => []
      },
      Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    )
  end

  def runner_result(attrs \\ []) do
    struct!(
      %Harness.Runs.Runner.Result{run_id: 0, subtype: "success"},
      attrs
    )
  end

  @doc """
  Create a local "remote" the Repos manager can clone: a bare repo at
  `{base}/{owner}/{name}.git` seeded with README/CLAUDE.md/src file on main.
  Point `:github_remote_base` at `file://{base}/` for the test.
  """
  def create_git_remote!(base_dir, repo_name, extra_files \\ %{}) do
    bare = Path.join(base_dir, repo_name <> ".git")
    seed = Path.join(base_dir, "seed-" <> String.replace(repo_name, "/", "--"))

    File.mkdir_p!(bare)
    git!(base_dir, ["init", "--bare", "--initial-branch=main", bare])

    File.mkdir_p!(Path.join(seed, "src"))
    File.write!(Path.join(seed, "README.md"), "# #{repo_name}\n\nFixture repo.\n")
    File.write!(Path.join(seed, "CLAUDE.md"), "Run tests with `mix test`.\n")
    File.write!(Path.join(seed, "src/widget.ex"), "defmodule Widget do\nend\n")
    for {path, content} <- extra_files do
      full = Path.join(seed, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    git!(seed, ["init", "--initial-branch=main"])
    git!(seed, ["add", "-A"])

    git!(seed, [
      "-c",
      "user.name=fixture",
      "-c",
      "user.email=fixture@test",
      "commit",
      "-m",
      "seed"
    ])

    git!(seed, ["push", "file://" <> bare, "main:main"])
    File.rm_rf!(seed)

    bare
  end

  defp git!(cd, args) do
    {output, code} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    if code != 0, do: raise("fixture git #{Enum.join(args, " ")} failed: #{output}")
    output
  end
end
