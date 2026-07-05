defmodule Harness.UsageTest do
  use Harness.DataCase, async: false

  alias Harness.Usage
  alias Harness.Usage.{Sample, SubscriptionPool}

  @moduletag :capture_log

  defp sample(attrs) do
    struct!(%Sample{source: "oauth_api", raw: %{}, sampled_at: DateTime.utc_now()}, attrs)
  end

  describe "mode_for/2 (§7 thresholds)" do
    test "the gate ladder" do
      policy = Harness.Policy.get()

      assert Usage.mode_for(sample(seven_day_utilization: 10.0), policy) == :full_auto
      assert Usage.mode_for(sample(seven_day_utilization: 59.9), policy) == :full_auto
      assert Usage.mode_for(sample(seven_day_utilization: 60.0), policy) == :defer_ideation
      assert Usage.mode_for(sample(seven_day_utilization: 79.9), policy) == :defer_ideation
      assert Usage.mode_for(sample(seven_day_utilization: 80.0), policy) == :plan_only
      assert Usage.mode_for(sample(seven_day_utilization: 89.9), policy) == :plan_only
      assert Usage.mode_for(sample(seven_day_utilization: 90.0), policy) == :pause
      assert Usage.mode_for(sample(seven_day_utilization: 100.0), policy) == :pause
    end

    test "the WORST of the utilizations governs" do
      policy = Harness.Policy.get()

      s = sample(seven_day_utilization: 10.0, five_hour_utilization: 95.0)
      assert Usage.mode_for(s, policy) == :pause

      s = sample(seven_day_utilization: 10.0, seven_day_opus_utilization: 85.0)
      assert Usage.mode_for(s, policy) == :plan_only
    end

    test "a sample with no readable utilization fails closed to pause" do
      assert Usage.mode_for(sample([]), Harness.Policy.get()) == :pause
    end
  end

  describe "current_mode/0 fail-closed staleness" do
    test "no oauth sample at all → plan_only + stale" do
      assert Usage.current_mode() == :plan_only
      assert Usage.health() == :stale
    end

    test "a fresh sample governs; an old one is stale" do
      Usage.record_oauth_sample!(%{seven_day_utilization: 10.0, raw: %{}})
      assert Usage.current_mode() == :full_auto
      assert Usage.health() == :ok

      # age the sample past 3 × poll_minutes (30 min)
      Harness.Repo.update_all(Sample,
        set: [sampled_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      assert Usage.current_mode() == :plan_only
      assert Usage.health() == :stale
    end

    test "rate_limit_event samples alone do NOT satisfy freshness" do
      run = Harness.Runs.create_run!(%{kind: "plan", status: "running"})

      Usage.ingest_rate_limit_event(run, %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{"status" => "allowed", "isUsingOverage" => false}
      })

      assert Usage.health() == :stale
      assert Usage.current_mode() == :plan_only
    end

    test "3 consecutive nil-util oauth samples → health :schema_drift" do
      for _ <- 1..3 do
        Usage.record_oauth_sample!(%{raw: %{"rate_limit_info" => %{}}})
      end

      assert Usage.health() == :schema_drift
    end

    test "fewer than 3 nil-util oauth samples → health :stale not :schema_drift" do
      for _ <- 1..2 do
        Usage.record_oauth_sample!(%{raw: %{"rate_limit_info" => %{}}})
      end

      assert Usage.health() == :stale
    end
  end

  describe "record_oauth_sample!/1" do
    test "broadcasts the sample and mode changes" do
      Usage.subscribe()

      Usage.record_oauth_sample!(%{seven_day_utilization: 10.0, raw: %{}})
      assert_receive {:usage_sample, _}
      assert_receive {:usage_mode_changed, :full_auto}

      Usage.record_oauth_sample!(%{seven_day_utilization: 95.0, raw: %{}})
      assert_receive {:usage_sample, _}
      assert_receive {:usage_mode_changed, :pause}

      # same mode again → no mode-change broadcast
      Usage.record_oauth_sample!(%{seven_day_utilization: 96.0, raw: %{}})
      assert_receive {:usage_sample, _}
      refute_receive {:usage_mode_changed, _}, 50
    end
  end

  describe "SubscriptionPool" do
    test "parses the community-documented endpoint shape" do
      attrs =
        SubscriptionPool.parse(%{
          "five_hour" => %{"utilization" => 42, "resets_at" => "2026-07-04T20:00:00Z"},
          "seven_day" => %{"utilization" => 63.5, "resets_at" => "2026-07-11T00:00:00Z"},
          "seven_day_opus" => %{"utilization" => 12}
        })

      assert attrs.five_hour_utilization == 42.0
      assert attrs.seven_day_utilization == 63.5
      assert attrs.seven_day_opus_utilization == 12.0
      assert %DateTime{} = attrs.five_hour_resets_at
    end

    test "parses the new rate_limit_info shape when isUsingOverage is true" do
      attrs =
        SubscriptionPool.parse(%{
          "rate_limit_info" => %{
            "rateLimitType" => "five_hour",
            "resetsAt" => 1_783_212_000,
            "isUsingOverage" => true,
            "overageStatus" => "allowed",
            "overageResetsAt" => 1_783_200_600
          }
        })

      assert attrs.five_hour_utilization == 90.0
      assert %DateTime{} = attrs.five_hour_resets_at
      assert is_nil(attrs.seven_day_utilization)
      assert is_nil(attrs.seven_day_opus_utilization)
      refute is_nil(attrs.raw)
    end

    test "new rate_limit_info shape with overageStatus paused infers 100% utilization" do
      attrs =
        SubscriptionPool.parse(%{
          "rate_limit_info" => %{
            "rateLimitType" => "five_hour",
            "resetsAt" => 1_783_212_000,
            "isUsingOverage" => true,
            "overageStatus" => "paused"
          }
        })

      assert attrs.five_hour_utilization == 100.0
    end

    test "new rate_limit_info shape with no overage infers nil utilization" do
      attrs =
        SubscriptionPool.parse(%{
          "rate_limit_info" => %{
            "rateLimitType" => "five_hour",
            "resetsAt" => 1_783_212_000,
            "isUsingOverage" => false,
            "overageStatus" => "allowed",
            "overageResetsAt" => 1_783_200_600
          }
        })

      assert is_nil(attrs.five_hour_utilization)
      refute is_nil(attrs.raw)
    end

    test "falls back to legacy shape when rate_limit_info is absent" do
      attrs =
        SubscriptionPool.parse(%{
          "five_hour" => %{"utilization" => 42, "resets_at" => "2026-07-04T20:00:00Z"},
          "seven_day" => %{"utilization" => 63.5, "resets_at" => "2026-07-11T00:00:00Z"},
          "seven_day_opus" => %{"utilization" => 12}
        })

      assert attrs.five_hour_utilization == 42.0
      assert attrs.seven_day_utilization == 63.5
      assert attrs.seven_day_opus_utilization == 12.0
    end

    test "fetch_usage sends the OAuth bearer + claude-code user-agent" do
      Application.put_env(:harness, :usage_req_options, plug: {Req.Test, __MODULE__})
      on_exit(fn -> Application.delete_env(:harness, :usage_req_options) end)

      Req.Test.stub(__MODULE__, fn conn ->
        assert ["Bearer test-oauth-token"] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["claude-code/" <> _] = Plug.Conn.get_req_header(conn, "user-agent")

        Req.Test.json(conn, %{
          "five_hour" => %{"utilization" => 5},
          "seven_day" => %{"utilization" => 20}
        })
      end)

      assert {:ok, attrs} = SubscriptionPool.fetch_usage()
      assert attrs.seven_day_utilization == 20.0
    end

    test "fetch_usage surfaces failures for the fail-closed path" do
      Application.put_env(:harness, :usage_req_options, plug: {Req.Test, __MODULE__})
      on_exit(fn -> Application.delete_env(:harness, :usage_req_options) end)

      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)
      assert {:error, {:http_status, 429}} = SubscriptionPool.fetch_usage()
    end
  end

  describe "weekly aggregates from runs" do
    test "opus hours and overflow dollars" do
      now = DateTime.utc_now()

      Harness.Runs.create_run!(%{kind: "critique", status: "succeeded", model: "opus"})
      |> Harness.Runs.update_run!(%{
        started_at: DateTime.add(now, -7200, :second),
        ended_at: DateTime.add(now, -3600, :second)
      })

      Harness.Runs.create_run!(%{kind: "plan", status: "succeeded", model: "sonnet"})
      |> Harness.Runs.update_run!(%{
        started_at: DateTime.add(now, -7200, :second),
        ended_at: now,
        used_overage: true,
        cost_estimate: 1.25
      })

      assert_in_delta Usage.opus_hours_this_week(), 1.0, 0.01
      assert_in_delta Usage.overflow_usd_this_week(), 1.25, 0.001
    end
  end
end
