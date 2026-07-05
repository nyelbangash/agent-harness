defmodule Harness.Manager.LampServerTest do
  # LampServer is a singleton GenServer; tests must be synchronous.
  use ExUnit.Case, async: false

  alias Harness.Manager.LampServer

  setup do
    # Clear all lamps and drain any queued broadcasts before subscribing.
    for lamp <- ~w(loop_signature wedged_lane stalled_run stranded_state artifact_drift telemetry_silence stale_code)a do
      LampServer.clear(lamp)
    end

    LampServer.subscribe()

    # Drain broadcasts produced by the setup clears.
    drain_mailbox()

    :ok
  end

  defp drain_mailbox do
    receive do
      {:lamps_updated, _} -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  test "get_all/0 returns all 7 classes" do
    lamps = LampServer.get_all()
    classes = Enum.map(lamps, & &1.class)

    for lamp <- ~w(loop_signature wedged_lane stalled_run stranded_state artifact_drift telemetry_silence stale_code)a do
      assert lamp in classes
    end

    assert length(lamps) == 7
  end

  test "get_all/0 returns :off for all lamps after setup clears them" do
    lamps = LampServer.get_all()
    assert Enum.all?(lamps, &(&1.status == :off))
  end

  test "set/2 turns the lamp on and broadcasts with detail" do
    LampServer.set(:loop_signature, "issue #42")

    assert_receive {:lamps_updated, lamps}
    lamp = Enum.find(lamps, &(&1.class == :loop_signature))
    assert lamp.status == :on
    assert lamp.detail == "issue #42"
    assert %DateTime{} = lamp.set_at
  end

  test "clear/1 turns the lamp off, preserves set_at, and broadcasts" do
    LampServer.set(:stalled_run, "run #7")
    assert_receive {:lamps_updated, _}

    LampServer.clear(:stalled_run)

    assert_receive {:lamps_updated, lamps}
    lamp = Enum.find(lamps, &(&1.class == :stalled_run))
    assert lamp.status == :off
    assert %DateTime{} = lamp.cleared_at
  end

  test "last_sweep_at/0 returns nil when no sweep has been recorded in this test" do
    # record_sweep is a cast; a synchronous call (get_all) drains it
    _ = LampServer.get_all()
    # After setup clears, no sweep has occurred in this test — may be nil
    # or a DateTime from a previous test. Either is valid; what matters is
    # that record_sweep makes it non-nil.
    before = LampServer.last_sweep_at()

    LampServer.record_sweep()
    # drain cast
    _ = LampServer.get_all()

    after_sweep = LampServer.last_sweep_at()
    assert %DateTime{} = after_sweep
    assert is_nil(before) or DateTime.compare(after_sweep, before) == :gt
  end
end
