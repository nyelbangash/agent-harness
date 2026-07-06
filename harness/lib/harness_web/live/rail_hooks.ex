defmodule HarnessWeb.RailHooks do
  @moduledoc """
  Shared behavior for every Mission Control LiveView: the left rail's state
  (mode + usage health), the master-kill and per-run kill events, and the
  current path for nav highlighting. Domain messages pass through to each
  LiveView's own `handle_info`.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Harness.PubSub, "policy")
      Phoenix.PubSub.subscribe(Harness.PubSub, "usage")
      # staleness is a silent time-based transition (no broadcast fires when
      # the last sample ages out) — refresh the rail on a slow tick
      :timer.send_interval(60_000, self(), :rail_tick)
    end

    socket =
      socket
      |> assign(rail_state())
      |> assign(:current_path, "/")
      |> attach_hook(:rail_path, :handle_params, &handle_params/3)
      |> attach_hook(:rail_events, :handle_event, &handle_event/3)
      |> attach_hook(:rail_info, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_params(_params, uri, socket) do
    {:cont, assign(socket, :current_path, URI.parse(uri).path || "/")}
  end

  defp handle_event("master_kill", _params, socket) do
    Harness.Runs.kill_all()
    {:halt, put_flash(socket, :info, "Kill signal sent to every running session")}
  end

  defp handle_event("kill_run", %{"id" => id}, socket) do
    case Harness.Runs.kill(String.to_integer(id)) do
      :ok -> {:halt, put_flash(socket, :info, "Kill signal sent to run ##{id}")}
      {:error, :not_running} -> {:halt, put_flash(socket, :error, "Run ##{id} is not running")}
    end
  end

  defp handle_event("set_mode", %{"mode" => mode}, socket)
       when mode in ["plan_only", "full_auto", "paused"] do
    :ok = Harness.Policy.set_mode!(String.to_existing_atom(mode))

    {:halt,
     socket
     |> assign(rail_state())
     |> put_flash(:info, "Mode set to #{String.replace(mode, "_", " ")}")}
  end

  defp handle_event("promote_to_auto", %{"id" => id}, socket) do
    issue_id = String.to_integer(id)

    case Harness.GitHub.promote_to_auto(issue_id) do
      {:ok, _issue} ->
        {:halt, put_flash(socket, :info, "Promoted to auto — implement session queued")}

      {:already_queued, _issue} ->
        {:halt, put_flash(socket, :info, "Already queued for implementation")}
    end
  end

  defp handle_event("retry_issue", %{"id" => id}, socket) do
    issue_id = String.to_integer(id)

    if Harness.GitHub.active_pipeline_job?(issue_id) do
      {:halt, put_flash(socket, :info, "Already queued or running — nothing to do")}
    else
      issue = Harness.GitHub.get_issue!(issue_id)
      enqueue_retry(issue, socket)
    end
  end

  defp enqueue_retry(issue, socket) do
    case Harness.Runs.latest_issue_run_kind(issue.id) do
      "triage" ->
        Harness.GitHub.transition!(issue, "incoming")
        %{issue_id: issue.id} |> Harness.GitHub.TriageWorker.new() |> Oban.insert()
        {:halt, put_flash(socket, :info, "Triage re-queued")}

      "implement" ->
        Harness.GitHub.transition!(issue, "triaged")

        %{issue_id: issue.id, promoted: true}
        |> Harness.GitHub.ImplementWorker.new()
        |> Oban.insert()

        {:halt, put_flash(socket, :info, "Implement re-queued")}

      _ ->
        # "plan" run kind or nil (no run record) — re-queue PlanWorker
        Harness.GitHub.transition!(issue, "triaged")
        %{issue_id: issue.id} |> Harness.GitHub.PlanWorker.new() |> Oban.insert()
        {:halt, put_flash(socket, :info, "Plan re-queued")}
    end
  end

  defp handle_event("enqueue_review", %{"id" => id}, socket) do
    with_open_pr(socket, id, fn issue ->
      %{
        issue_id: issue.id,
        pr_number: issue.pr_number,
        round: 0,
        branch: Harness.GitHub.Issue.branch_name(issue)
      }
      |> Harness.GitHub.ReviewWorker.new()
      |> Oban.insert()

      "Adversarial review queued"
    end)
  end

  defp handle_event("enqueue_bug_hunt", %{"id" => id}, socket) do
    enqueue_operator_pass(socket, id, operator_pass_prompt(:bug_hunt), "Bug-hunt pass queued")
  end

  defp handle_event("enqueue_format", %{"id" => id}, socket) do
    enqueue_operator_pass(socket, id, operator_pass_prompt(:format), "Format pass queued")
  end

  defp handle_event("post_thread_comment", %{"issue_id" => id, "body" => body}, socket) do
    body = String.trim(body)
    issue = Harness.GitHub.get_issue!(String.to_integer(id))
    target_number = issue.pr_number || issue.number

    if body == "" do
      {:halt, socket}
    else
      case Harness.GitHub.Client.post_issue_comment(issue.repo, target_number, body) do
        {:ok, _comment_id, _created_at} ->
          {:halt,
           put_flash(
             socket,
             :info,
             "Comment posted — the harness will pick it up on the next poll."
           )}

        {:error, reason} ->
          {:halt, put_flash(socket, :error, "GitHub error: #{inspect(reason)}")}
      end
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp with_open_pr(socket, id, fun) do
    issue = Harness.GitHub.get_issue!(String.to_integer(id))

    if issue.pr_number do
      {:halt, put_flash(socket, :info, fun.(issue))}
    else
      {:halt, put_flash(socket, :error, "No open PR for this issue")}
    end
  end

  # Bug-hunt/format one-click actions reuse RespondWorker's existing
  # pre-flight/fix worker rather than introducing new job types — the same
  # scoped-continuation path a real operator PR comment takes, just
  # dispatched immediately instead of waiting for the next poll sweep. The
  # synthetic (negative) comment_id can never collide with a real GitHub id.
  defp enqueue_operator_pass(socket, id, prompt, flash_message) do
    with_open_pr(socket, id, fn issue ->
      attrs = %{
        repo: issue.repo,
        pr_number: issue.pr_number,
        comment_id: -System.unique_integer([:positive]),
        comment_type: "issue"
      }

      {:inserted, handle} = Harness.GitHub.maybe_insert_pr_comment_handle!(attrs)

      %{
        pr_comment_handle_id: handle.id,
        issue_id: issue.id,
        comment_body: prompt,
        comment_path: nil,
        comment_line: nil,
        comment_diff_hunk: nil
      }
      |> Harness.GitHub.RespondWorker.new()
      |> Oban.insert()

      flash_message
    end)
  end

  defp operator_pass_prompt(:bug_hunt) do
    "Do an adversarial bug-hunt pass over this branch: look for correctness bugs, " <>
      "edge cases, and regressions the existing tests don't cover. If you find real " <>
      "bugs, fix them and add a test proving the fix. If you find nothing, say so."
  end

  defp operator_pass_prompt(:format) do
    "Run the project's formatter/linter over this branch and fix any formatting or " <>
      "style violations. Do not change behavior."
  end

  defp handle_info(:rail_tick, socket), do: {:halt, assign(socket, rail_state())}
  defp handle_info({:policy_reloaded, _}, socket), do: {:cont, assign(socket, rail_state())}
  defp handle_info({:policy_error, _}, socket), do: {:cont, assign(socket, rail_state())}
  defp handle_info({:usage_mode_changed, _}, socket), do: {:cont, assign(socket, rail_state())}
  defp handle_info({:usage_sample, _}, socket), do: {:cont, assign(socket, rail_state())}
  defp handle_info(_message, socket), do: {:cont, socket}

  defp rail_state do
    %{
      mode: Harness.Policy.mode(),
      usage_mode: Harness.Usage.current_mode(),
      usage_health: Harness.Usage.health()
    }
  end
end
