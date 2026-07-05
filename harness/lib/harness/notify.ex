defmodule Harness.Notify do
  @moduledoc """
  Operator notifications (spec §9.6): a macOS banner via `osascript` plus an
  optional ntfy.sh topic (from `policy.yaml → notify`). Fired on the events
  that need a human: PR opened, plan ready, run failed, gates tripped, budget
  ≥ 80%.

  The delivery backend is swappable (`:harness, :notify_backend`) so tests
  capture instead of shelling out. Delivery is best-effort and never raises
  into the caller — a failed notification must not fail a pipeline job.
  """

  require Logger

  @type event ::
          :pr_opened
          | :plan_ready
          | :run_failed
          | :gate_tripped
          | :budget_warning
          | :ideation_synthesized
          | :promote_complete
          | :briefing
          | :conflict_escalated
          | :manager_proposal

  @spec notify(event(), String.t(), keyword()) :: :ok
  def notify(event, message, opts \\ []) do
    title = "Harness · #{title_for(event)}"
    backend().deliver(event, title, message, opts)
    :ok
  rescue
    e ->
      Logger.warning("notification failed: #{Exception.message(e)}")
      :ok
  end

  defp title_for(:pr_opened), do: "PR opened"
  defp title_for(:plan_ready), do: "Plan ready"
  defp title_for(:run_failed), do: "Run failed"
  defp title_for(:gate_tripped), do: "Gate tripped"
  defp title_for(:budget_warning), do: "Budget warning"
  defp title_for(:ideation_synthesized), do: "Ideation synthesized"
  defp title_for(:promote_complete), do: "Promote complete"
  defp title_for(:briefing), do: "Morning briefing"
  defp title_for(:conflict_escalated), do: "Conflict needs human attention"
  defp title_for(:manager_proposal), do: "Manager proposal"

  defp backend, do: Application.get_env(:harness, :notify_backend, __MODULE__.System)

  # -- delivery behaviour + real backend --------------------------------------

  defmodule Backend do
    @callback deliver(atom(), String.t(), String.t(), keyword()) :: any()
  end

  defmodule System do
    @moduledoc "macOS banner + optional ntfy.sh topic."
    @behaviour Harness.Notify.Backend

    @impl true
    def deliver(event, title, message, _opts) do
      macos_banner(title, message)
      ntfy(event, title, message)
    end

    defp macos_banner(title, message) do
      script =
        ~s(display notification #{osa_quote(message)} with title #{osa_quote(title)})

      _ = Elixir.System.cmd("osascript", ["-e", script], stderr_to_stdout: true)
    end

    defp ntfy(event, title, message) do
      case Harness.Policy.get().notify do
        %{ntfy_topic: topic} when is_binary(topic) and topic != "" ->
          Req.post(
            url: "https://ntfy.sh/#{topic}",
            headers: [{"title", title}, {"tags", to_string(event)}],
            body: message,
            retry: false,
            receive_timeout: 5_000
          )

        _ ->
          :ok
      end
    end

    # AppleScript string literal: wrap in quotes, escape backslashes + quotes
    defp osa_quote(text) do
      escaped = text |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
      "\"" <> escaped <> "\""
    end
  end
end
