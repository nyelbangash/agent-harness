defmodule Harness.VerifierTest do
  use ExUnit.Case, async: true

  alias Harness.Policy.Schema.Repo, as: RepoCfg
  alias Harness.Verifier

  setup do
    tmp = Path.join(System.tmp_dir!(), "verifier-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "green when every configured command exits 0", %{tmp: tmp} do
    cfg = %RepoCfg{name: "o/r", test_command: "true", lint_command: "true"}
    assert :ok = Verifier.verify(tmp, cfg)
  end

  test "nil/empty commands are skipped", %{tmp: tmp} do
    cfg = %RepoCfg{name: "o/r", test_command: "true", lint_command: nil, typecheck_command: ""}
    assert :ok = Verifier.verify(tmp, cfg)
  end

  test "a failing command yields a labeled transcript with output", %{tmp: tmp} do
    cfg = %RepoCfg{name: "o/r", test_command: "echo the-widget-broke && exit 3"}

    assert {:failed, transcript} = Verifier.verify(tmp, cfg)
    assert transcript =~ "test command failed (exit 3)"
    assert transcript =~ "the-widget-broke"
  end

  test "stops at the first failure in test → lint → typecheck order", %{tmp: tmp} do
    cfg = %RepoCfg{
      name: "o/r",
      test_command: "true",
      lint_command: "echo lint-sad && false",
      typecheck_command: "echo should-not-run"
    }

    assert {:failed, transcript} = Verifier.verify(tmp, cfg)
    assert transcript =~ "lint command failed"
    refute transcript =~ "should-not-run"
  end

  test "commands run in the worktree", %{tmp: tmp} do
    File.write!(Path.join(tmp, "marker.txt"), "here")
    cfg = %RepoCfg{name: "o/r", test_command: "test -f marker.txt"}
    assert :ok = Verifier.verify(tmp, cfg)
  end
end
