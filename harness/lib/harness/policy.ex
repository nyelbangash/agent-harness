defmodule Harness.Policy do
  @moduledoc """
  Public policy API. Every worker calls `gate/1` before doing model work —
  the model proposes, the policy disposes.

  `gate/1` composes three inputs:

    * configured `mode` from policy.yaml (plan_only | full_auto | paused)
    * schedule windows (local time)
    * the usage-derived mode from `Harness.Usage.current_mode/0`
      (full_auto | defer_ideation | plan_only | pause, per §7 thresholds)
  """

  alias Harness.Policy.Schema

  @type action :: :triage | :plan | :implement | :ideate
  @type gate_result :: :ok | {:snooze, pos_integer(), atom()} | {:skip, atom()}

  @paused_snooze_seconds 300

  @spec get() :: Schema.t()
  def get, do: Harness.Policy.Server.current()

  @spec mode() :: :plan_only | :full_auto | :paused
  def mode, do: get().mode

  @spec reload() :: :ok | {:error, [String.t()]}
  def reload, do: Harness.Policy.Server.reload()

  @spec gate?(action()) :: boolean()
  def gate?(action), do: gate(action) == :ok

  @spec gate(action(), keyword()) :: gate_result()
  def gate(action, opts \\ [])

  def gate(action, opts) when action in [:triage, :plan, :implement, :ideate] do
    policy = Keyword.get(opts, :policy, get())
    usage_mode = Keyword.get_lazy(opts, :usage_mode, &Harness.Usage.current_mode/0)
    now = Keyword.get_lazy(opts, :now, &local_time/0)

    cond do
      policy.mode == :paused -> {:snooze, @paused_snooze_seconds, :paused}
      usage_mode == :pause -> {:snooze, usage_snooze(policy), :usage_pause}
      true -> gate_action(action, policy, usage_mode, now)
    end
  end

  # Triage and plan lanes run in every non-paused mode; utilization gating for
  # them is the global :pause threshold handled above.
  defp gate_action(:triage, _policy, _usage, _now), do: :ok
  defp gate_action(:plan, _policy, _usage, _now), do: :ok

  defp gate_action(:implement, policy, usage_mode, now) do
    cond do
      policy.mode != :full_auto ->
        {:skip, :mode_not_full_auto}

      usage_mode != :full_auto ->
        {:skip, :usage_above_full_auto_threshold}

      not in_windows?(now, policy.schedule.full_auto_windows) ->
        {:skip, :outside_full_auto_window}

      true ->
        :ok
    end
  end

  defp gate_action(:ideate, policy, usage_mode, now) do
    cond do
      usage_mode in [:defer_ideation, :plan_only] ->
        {:skip, :usage_defers_ideation}

      not in_windows?(now, policy.schedule.ideation_windows) ->
        {:snooze, seconds_until_window(now, policy.schedule.ideation_windows),
         :outside_ideation_window}

      true ->
        :ok
    end
  end

  @doc """
  True only when the auto lane is fully open: configured full_auto, inside a
  full-auto window, and utilization below the full-auto threshold. Used by
  triage routing (§4.2) — outside this, `auto` proposals demote to `plan`.
  """
  @spec full_auto_active?(keyword()) :: boolean()
  def full_auto_active?(opts \\ []) do
    gate(:implement, opts) == :ok
  end

  @doc "Is `time` inside any of the windows? Windows may wrap midnight."
  @spec in_windows?(Time.t(), [{Time.t(), Time.t()}]) :: boolean()
  def in_windows?(_time, []), do: false

  def in_windows?(time, windows) do
    Enum.any?(windows, fn {from, to} ->
      if Time.compare(from, to) in [:lt, :eq] do
        Time.compare(time, from) != :lt and Time.compare(time, to) == :lt
      else
        # wraps midnight, e.g. 20:00-06:00
        Time.compare(time, from) != :lt or Time.compare(time, to) == :lt
      end
    end)
  end

  @doc "Seconds from `now` until the next window opens (86400 max)."
  @spec seconds_until_window(Time.t(), [{Time.t(), Time.t()}]) :: pos_integer()
  def seconds_until_window(_now, []), do: 86_400

  def seconds_until_window(now, windows) do
    windows
    |> Enum.map(fn {from, _to} ->
      case Time.diff(from, now) do
        diff when diff > 0 -> diff
        diff -> diff + 86_400
      end
    end)
    |> Enum.min()
  end

  defp usage_snooze(policy), do: policy.utilization_gates.poll_minutes * 60

  defp local_time do
    NaiveDateTime.local_now() |> NaiveDateTime.to_time()
  end
end
