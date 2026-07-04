defmodule Harness.Runs.EventIngestTest do
  use Harness.DataCase, async: false

  alias Harness.Runs
  alias Harness.Runs.EventIngest

  @fixtures Path.expand("../../support/fixtures/ndjson", __DIR__)

  defp make_run do
    Runs.create_run!(%{kind: "plan", status: "running", model: "sonnet"})
  end

  defp ingest_fixture(run, file) do
    @fixtures
    |> Path.join(file)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.map(fn {line, seq} -> EventIngest.ingest(run, seq, line) end)
  end

  test "a real captured stream lands every line as a typed, ordered event" do
    run = make_run()
    outcomes = ingest_fixture(run, "happy_tool_use.ndjson")

    events = Runs.events(run.id)
    assert length(events) == 10
    assert Enum.map(events, & &1.seq) == Enum.to_list(1..10)

    # init first, result last
    assert {:init, session_id} = hd(outcomes)
    assert is_binary(session_id)
    assert {:result, %{"subtype" => "success"} = result} = List.last(outcomes)
    assert result["num_turns"]

    # the tool-using assistant message became a tool_use event; the tool reply
    # a tool_result; unknown system subtypes (thinking_tokens) became system
    types = Enum.map(events, & &1.type)
    assert "tool_use" in types
    assert "tool_result" in types
    assert "text" in types
    assert Enum.count(types, &(&1 == "system")) >= 4
  end

  test "rate_limit_event records a usage sample" do
    run = make_run()
    ingest_fixture(run, "happy_tool_use.ndjson")

    samples = Harness.Usage.latest_samples()
    assert %{"rate_limit_event" => sample} = samples
    assert sample.rate_limit_status == "allowed"
    assert sample.raw["rate_limit_info"]["rateLimitType"] == "five_hour"
  end

  test "turn outcomes carry the message id so split messages count once" do
    run = make_run()
    outcomes = ingest_fixture(run, "happy_tool_use.ndjson")

    turn_ids = for {:turn, id} <- outcomes, do: id
    # 3 assistant events in the fixture, but only 2 distinct API messages
    assert length(turn_ids) == 3
    assert length(Enum.uniq(turn_ids)) == 2
  end

  test "error result subtypes categorize as error events and still yield the result" do
    run = make_run()
    outcomes = ingest_fixture(run, "error_max_turns.ndjson")

    assert {:result, %{"subtype" => "error_max_turns"}} = List.last(outcomes)
    assert Enum.any?(Runs.events(run.id), &(&1.type == "error"))
  end

  test "unknown event types and non-JSON lines never crash the stream" do
    run = make_run()
    outcomes = ingest_fixture(run, "unknown_events.ndjson")

    assert Enum.count(outcomes, &(&1 == :other)) == 2
    assert :bad_line in outcomes
    assert {:result, _} = List.last(outcomes)

    events = Runs.events(run.id)
    assert Enum.any?(events, &(&1.type == "error" and &1.payload["note"] == "unparseable line"))
  end

  test "result_fields extracts run totals from the envelope" do
    payload = %{
      "subtype" => "success",
      "session_id" => "abc",
      "num_turns" => 3,
      "total_cost_usd" => 0.05,
      "usage" => %{
        "input_tokens" => 10,
        "cache_creation_input_tokens" => 100,
        "cache_read_input_tokens" => 1000,
        "output_tokens" => 42
      }
    }

    fields = EventIngest.result_fields(payload)
    assert fields.result_subtype == "success"
    assert fields.turns == 3
    assert fields.tokens_in == 1110
    assert fields.tokens_out == 42
    assert fields.cost_estimate == 0.05
  end
end
