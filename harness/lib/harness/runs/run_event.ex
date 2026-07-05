defmodule Harness.Runs.RunEvent do
  @moduledoc """
  One NDJSON line from a runner, typed into the spec §6 vocabulary
  (`text | tool_use | tool_result | error | system`) with the full decoded
  payload preserved. Insert-only.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(text tool_use tool_result error system phase verifier_output)

  schema "run_events" do
    belongs_to :run, Harness.Runs.Run

    field :seq, :integer
    field :type, :string
    field :payload, :map
    field :at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def types, do: @types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:run_id, :seq, :type, :payload, :at])
    |> validate_required([:run_id, :seq, :type, :payload, :at])
    |> validate_inclusion(:type, @types)
    |> unique_constraint([:run_id, :seq])
    |> foreign_key_constraint(:run_id)
  end
end
