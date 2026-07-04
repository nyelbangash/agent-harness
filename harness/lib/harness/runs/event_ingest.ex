defmodule Harness.Runs.EventIngest do
  @moduledoc """
  Decodes one NDJSON line from a runner into the spec §6 event vocabulary,
  persists it, broadcasts it, and tells the RunServer what it saw.

  Robustness rules (verified against CLI 2.1.195 and its docs):

    * unknown `type`/`subtype` values are persisted as `system` events and
      never crash the stream — there is no exhaustive official list
    * success/failure is derived from the result envelope's `subtype`
      (`success` vs `error_*`), never from `is_error` (historically wrong)
    * `rate_limit_event` doubles as a usage signal (five-hour window +
      overage flags) and feeds `usage_samples`
  """

  alias Harness.Runs

  @type outcome ::
          {:init, session_id :: String.t()}
          | {:turn, message_id :: String.t() | nil}
          | {:result, map()}
          | {:overage, boolean()}
          | :other
          | :bad_line

  @spec ingest(Harness.Runs.Run.t(), non_neg_integer(), String.t()) :: outcome()
  def ingest(run, seq, line) do
    case Jason.decode(line) do
      {:ok, %{} = payload} ->
        {type, outcome} = categorize(payload)
        Runs.append_event!(run, seq, type, payload)
        side_effects(run, payload, outcome)
        outcome

      _ ->
        trimmed = String.slice(line, 0, 2_000)

        if String.trim(trimmed) != "" do
          Runs.append_event!(run, seq, "error", %{"raw" => trimmed, "note" => "unparseable line"})
        end

        :bad_line
    end
  end

  @doc "Map a decoded payload to {event_type, outcome} without side effects."
  @spec categorize(map()) :: {String.t(), outcome()}
  def categorize(%{"type" => "system", "subtype" => "init"} = payload) do
    {"system", {:init, payload["session_id"]}}
  end

  def categorize(%{"type" => "assistant"} = payload) do
    blocks = get_in(payload, ["message", "content"]) || []
    tool_use? = is_list(blocks) and Enum.any?(blocks, &(is_map(&1) and &1["type"] == "tool_use"))
    # one API message can arrive as several assistant events (one per content
    # block) — the message id lets the RunServer count real turns
    {if(tool_use?, do: "tool_use", else: "text"), {:turn, get_in(payload, ["message", "id"])}}
  end

  def categorize(%{"type" => "user"}), do: {"tool_result", :other}

  def categorize(%{"type" => "result", "subtype" => "success"} = payload) do
    {"system", {:result, payload}}
  end

  def categorize(%{"type" => "result"} = payload) do
    {"error", {:result, payload}}
  end

  def categorize(%{"type" => "rate_limit_event"} = payload) do
    overage = get_in(payload, ["rate_limit_info", "isUsingOverage"]) == true
    {"system", {:overage, overage}}
  end

  def categorize(%{"type" => "system", "subtype" => "api_retry"}), do: {"system", :other}
  def categorize(_payload), do: {"system", :other}

  defp side_effects(run, payload, {:overage, _}) do
    Harness.Usage.ingest_rate_limit_event(run, payload)
  end

  defp side_effects(_run, _payload, _outcome), do: :ok

  @doc """
  Distill a result envelope into run-level fields. Prefers the envelope's
  own totals; missing fields fall back to accumulated stream counts.
  """
  @spec result_fields(map()) :: map()
  def result_fields(%{} = payload) do
    usage = payload["usage"] || %{}

    %{
      result_subtype: payload["subtype"],
      session_id: payload["session_id"],
      turns: payload["num_turns"],
      cost_estimate: payload["total_cost_usd"],
      tokens_in:
        (usage["input_tokens"] || 0) +
          (usage["cache_creation_input_tokens"] || 0) +
          (usage["cache_read_input_tokens"] || 0),
      tokens_out: usage["output_tokens"] || 0
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
