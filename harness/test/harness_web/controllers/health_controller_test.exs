defmodule HarnessWeb.HealthControllerTest do
  use HarnessWeb.ConnCase

  @pt_poll_key {Harness.GitHub.PollWorker, :last_sweep_at}
  @pt_policy_key {Harness.Policy.Server, :policy}

  setup do
    prev_poll = :persistent_term.get(@pt_poll_key, :missing)
    prev_policy = :persistent_term.get(@pt_policy_key, :missing)

    on_exit(fn ->
      restore = fn key, prev ->
        if prev == :missing,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, prev)
      end

      restore.(@pt_poll_key, prev_poll)
      restore.(@pt_policy_key, prev_policy)
    end)

    :persistent_term.put(@pt_policy_key, stub_policy())
    :ok
  end

  test "200 ok when heartbeat is fresh and policy is loaded", %{conn: conn} do
    :persistent_term.put(@pt_poll_key, System.system_time(:second))
    conn = get(conn, "/healthz")
    assert json_response(conn, 200)["status"] == "ok"
  end

  test "503 names poll_heartbeat when stamp is stale", %{conn: conn} do
    stale_ts = System.system_time(:second) - 999
    :persistent_term.put(@pt_poll_key, stale_ts)
    conn = get(conn, "/healthz")
    body = json_response(conn, 503)
    assert body["status"] == "degraded"
    assert "poll_heartbeat" in body["failing"]
  end

  test "503 names poll_heartbeat when no sweep has occurred", %{conn: conn} do
    :persistent_term.erase(@pt_poll_key)
    conn = get(conn, "/healthz")
    assert "poll_heartbeat" in json_response(conn, 503)["failing"]
  end

  test "503 names policy when policy is not loaded", %{conn: conn} do
    :persistent_term.put(@pt_poll_key, System.system_time(:second))
    :persistent_term.erase(@pt_policy_key)
    conn = get(conn, "/healthz")
    assert "policy" in json_response(conn, 503)["failing"]
  end

  defp stub_policy do
    %Harness.Policy.Schema{
      github: %Harness.Policy.Schema.GitHub{poll_minutes: 2}
    }
  end
end
