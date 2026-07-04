defmodule Harness.PolicyTest do
  # async: false — the server-integration test swaps the global :policy_path
  use ExUnit.Case, async: false

  alias Harness.Policy

  defp policy(overrides \\ %{}) do
    {:ok, raw} =
      Application.fetch_env!(:harness, :policy_path)
      |> YamlElixir.read_from_file()

    {:ok, policy} = Harness.Policy.Schema.parse(deep_merge(raw, overrides))
    policy
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _k, %{} = l, %{} = r -> deep_merge(l, r)
      _k, _l, r -> r
    end)
  end

  # inside the shipped 20:00-06:00 full-auto window / 21:00-02:00 ideation window
  @in_window ~T[22:00:00]
  @out_of_window ~T[12:00:00]

  describe "gate/2" do
    test "paused mode snoozes every lane" do
      p = policy(%{"mode" => "paused"})

      for action <- [:triage, :plan, :implement, :ideate] do
        assert {:snooze, _, :paused} =
                 Policy.gate(action, policy: p, usage_mode: :full_auto, now: @in_window)
      end
    end

    test "usage pause snoozes every lane" do
      p = policy()

      for action <- [:triage, :plan, :implement, :ideate] do
        assert {:snooze, seconds, :usage_pause} =
                 Policy.gate(action, policy: p, usage_mode: :pause, now: @in_window)

        assert seconds == p.utilization_gates.poll_minutes * 60
      end
    end

    test "triage and plan run in plan_only mode" do
      p = policy()
      assert :ok = Policy.gate(:triage, policy: p, usage_mode: :plan_only, now: @out_of_window)
      assert :ok = Policy.gate(:plan, policy: p, usage_mode: :plan_only, now: @out_of_window)
    end

    test "implement requires configured full_auto" do
      assert {:skip, :mode_not_full_auto} =
               Policy.gate(:implement, policy: policy(), usage_mode: :full_auto, now: @in_window)
    end

    test "implement requires usage below the full-auto threshold" do
      p = policy(%{"mode" => "full_auto"})

      assert {:skip, :usage_above_full_auto_threshold} =
               Policy.gate(:implement, policy: p, usage_mode: :plan_only, now: @in_window)
    end

    test "implement requires being inside a full-auto window" do
      p = policy(%{"mode" => "full_auto"})

      assert {:skip, :outside_full_auto_window} =
               Policy.gate(:implement, policy: p, usage_mode: :full_auto, now: @out_of_window)

      assert :ok = Policy.gate(:implement, policy: p, usage_mode: :full_auto, now: @in_window)
    end

    test "ideate defers on utilization and snoozes outside its window" do
      p = policy()

      assert {:skip, :usage_defers_ideation} =
               Policy.gate(:ideate, policy: p, usage_mode: :defer_ideation, now: @in_window)

      assert {:snooze, seconds, :outside_ideation_window} =
               Policy.gate(:ideate, policy: p, usage_mode: :full_auto, now: @out_of_window)

      # 12:00 -> 21:00 opens in 9h
      assert seconds == 9 * 3600

      assert :ok = Policy.gate(:ideate, policy: p, usage_mode: :full_auto, now: @in_window)
    end
  end

  describe "full_auto_active?/1 (feeds triage routing)" do
    test "only when mode, usage, and window all align" do
      full_auto = policy(%{"mode" => "full_auto"})

      assert Policy.full_auto_active?(policy: full_auto, usage_mode: :full_auto, now: @in_window)

      refute Policy.full_auto_active?(policy: policy(), usage_mode: :full_auto, now: @in_window)

      refute Policy.full_auto_active?(
               policy: full_auto,
               usage_mode: :defer_ideation,
               now: @in_window
             )

      refute Policy.full_auto_active?(
               policy: full_auto,
               usage_mode: :full_auto,
               now: @out_of_window
             )
    end
  end

  describe "in_windows?/2" do
    test "plain and midnight-wrapping windows" do
      plain = [{~T[09:00:00], ~T[17:00:00]}]
      assert Policy.in_windows?(~T[09:00:00], plain)
      assert Policy.in_windows?(~T[12:00:00], plain)
      refute Policy.in_windows?(~T[17:00:00], plain)
      refute Policy.in_windows?(~T[03:00:00], plain)

      wrapping = [{~T[20:00:00], ~T[06:00:00]}]
      assert Policy.in_windows?(~T[23:59:00], wrapping)
      assert Policy.in_windows?(~T[00:30:00], wrapping)
      assert Policy.in_windows?(~T[20:00:00], wrapping)
      refute Policy.in_windows?(~T[06:00:00], wrapping)
      refute Policy.in_windows?(~T[12:00:00], wrapping)

      refute Policy.in_windows?(~T[12:00:00], [])
    end
  end

  describe "server integration" do
    test "the app-started server serves the fixture policy and hot-reloads" do
      assert %Harness.Policy.Schema{mode: :plan_only} = Policy.get()

      tmp =
        Path.join(System.tmp_dir!(), "harness-policy-#{System.unique_integer([:positive])}.yaml")

      original = Application.fetch_env!(:harness, :policy_path)
      File.cp!(original, tmp)

      on_exit(fn ->
        Application.put_env(:harness, :policy_path, original)
        Harness.Policy.Server.reload()
        File.rm(tmp)
      end)

      content = File.read!(tmp) |> String.replace("mode: plan_only", "mode: full_auto")
      File.write!(tmp, content)
      Application.put_env(:harness, :policy_path, tmp)

      Phoenix.PubSub.subscribe(Harness.PubSub, "policy")
      assert :ok = Policy.reload()
      assert Policy.mode() == :full_auto
      assert_receive {:policy_reloaded, %{mode: :full_auto}}

      # a broken file keeps the previous good policy and broadcasts the error
      File.write!(tmp, "mode: [")
      assert {:error, _} = Policy.reload()
      assert Policy.mode() == :full_auto
      assert_receive {:policy_error, _}
    end
  end
end
