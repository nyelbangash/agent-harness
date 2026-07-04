defmodule Harness.Usage.Sample do
  @moduledoc """
  One utilization snapshot. Two sources feed this table:

    * `oauth_api` — the undocumented claude.ai usage endpoint (five-hour,
      seven-day, and seven-day-opus utilization, 0–100)
    * `rate_limit_event` — emitted by every real CLI run's stream; carries
      five-hour window status and overage flags, and keeps the gauges live
      even if the endpoint breaks

  Insert-only. Opus-hours and overflow-$ are aggregated from `runs`, not here.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(oauth_api rate_limit_event)

  schema "usage_samples" do
    field :source, :string
    field :five_hour_utilization, :float
    field :five_hour_resets_at, :utc_datetime_usec
    field :seven_day_utilization, :float
    field :seven_day_resets_at, :utc_datetime_usec
    field :seven_day_opus_utilization, :float
    field :rate_limit_status, :string
    field :raw, :map
    field :sampled_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def sources, do: @sources

  def changeset(sample, attrs) do
    sample
    |> cast(attrs, [
      :source,
      :five_hour_utilization,
      :five_hour_resets_at,
      :seven_day_utilization,
      :seven_day_resets_at,
      :seven_day_opus_utilization,
      :rate_limit_status,
      :raw,
      :sampled_at
    ])
    |> validate_required([:source, :raw, :sampled_at])
    |> validate_inclusion(:source, @sources)
  end
end
