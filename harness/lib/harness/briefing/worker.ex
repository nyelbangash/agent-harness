defmodule Harness.Briefing.Worker do
  @moduledoc """
  Assembles and persists the daily morning briefing. Scheduled via Oban cron
  at 07:00; retries up to 3 times on transient errors. The `since` window
  starts from the previous briefing's `inserted_at`, or 24 hours ago if none.
  """

  use Oban.Worker, queue: :ops, max_attempts: 3, unique: [period: 55]

  @impl Oban.Worker
  def perform(_job) do
    today = Date.utc_today()
    since = compute_since()
    {markdown, one_liner} = Harness.Briefing.assemble(since)
    Harness.Briefing.upsert!(today, markdown)
    Harness.Notify.notify(:briefing, one_liner)
    :ok
  end

  defp compute_since do
    case Harness.Briefing.latest_any() do
      nil -> DateTime.add(DateTime.utc_now(), -24 * 3600, :second)
      %{inserted_at: ts} -> ts
    end
  end
end
