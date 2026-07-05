defmodule Harness.Health do
  @pt_poll_key {Harness.GitHub.PollWorker, :last_sweep_at}
  @pt_policy_key {Harness.Policy.Server, :policy}

  def check do
    results = [check_oban(), check_poll_heartbeat(), check_policy()]
    failing = for {:error, name} <- results, do: name

    code_sha = get_code_sha()
    tree_sha = get_tree_sha()
    stale = code_sha != nil and tree_sha != nil and code_sha != tree_sha

    sha_info = %{"code_sha" => code_sha, "tree_sha" => tree_sha, "stale_code" => stale}

    if failing == [],
      do: {:ok, Map.merge(%{"status" => "ok"}, sha_info)},
      else: {:error, Map.merge(%{"status" => "degraded", "failing" => failing}, sha_info)}
  end

  defp check_oban do
    case Oban.whereis(Oban) do
      nil ->
        {:error, "oban"}

      _pid ->
        queues = Oban.config().queues

        any_paused =
          Enum.any?(queues, fn {q, _} ->
            try do
              result = Oban.check_queue(queue: q)
              Map.get(result, :paused, false)
            rescue
              _ -> false
            catch
              :exit, _ -> true
            end
          end)

        if any_paused, do: {:error, "oban"}, else: :ok
    end
  end

  defp check_poll_heartbeat do
    case :persistent_term.get(@pt_poll_key, nil) do
      nil ->
        {:error, "poll_heartbeat"}

      ts ->
        max_age_s = get_poll_minutes() * 3 * 60

        if System.system_time(:second) - ts <= max_age_s,
          do: :ok,
          else: {:error, "poll_heartbeat"}
    end
  end

  defp check_policy do
    case :persistent_term.get(@pt_policy_key, nil) do
      nil -> {:error, "policy"}
      _ -> :ok
    end
  end

  defp get_poll_minutes do
    case :persistent_term.get(@pt_policy_key, nil) do
      nil -> 2
      policy -> policy.github.poll_minutes
    end
  end

  defp get_code_sha do
    Application.get_env(:harness, :build_sha_override, Harness.BuildInfo.code_sha())
  end

  defp get_tree_sha do
    case Application.get_env(:harness, :tree_sha_override) do
      nil ->
        case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: false) do
          {sha, 0} -> String.trim(sha)
          _ -> nil
        end

      override ->
        override
    end
  end
end
