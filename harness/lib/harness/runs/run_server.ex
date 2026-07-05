defmodule Harness.Runs.RunServer do
  @moduledoc """
  Owns one headless claude OS process through an Erlang Port.

  Responsibilities: spawn with scrubbed env and isolation argv, stream stdout
  NDJSON into `EventIngest` (manual newline buffering — lines can exceed any
  fixed line cap), enforce the wall-clock timeout and the Elixir-side turn
  cap (belt-and-braces over `--max-turns`), and implement the kill switch
  (SIGTERM → 5s → SIGKILL). Finalization derives run status from the result
  envelope's `subtype` and replies to the awaiting `ClaudeCLI.execute/2`.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Harness.Repo
  alias Harness.Runs
  alias Harness.Runs.{CLIArgs, EventIngest, Runner}

  @sigkill_after :timer.seconds(5)

  def start_link({spec, run}) do
    GenServer.start_link(__MODULE__, {spec, run},
      name: {:via, Registry, {Harness.Runs.Registry, run.id}}
    )
  end

  @doc "Block until the run finishes. Called once, by the runner."
  def await(pid), do: GenServer.call(pid, :await, :infinity)

  @doc "Kill switch (UI button, master kill, `mix harness.stop`)."
  def kill(pid), do: GenServer.call(pid, {:kill, :user})

  # -- server ---------------------------------------------------------------------

  @impl true
  def init({spec, run}) do
    # trap exits so supervisor/VM shutdown reaches terminate/2 — otherwise the
    # claude OS process is orphaned mid-session (Port close sends no signal)
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       spec: spec,
       run: run,
       port: nil,
       os_pid: nil,
       buffer: "",
       seq: 0,
       turns: 0,
       last_message_id: nil,
       session_id: nil,
       result_payload: nil,
       overage: false,
       killed: nil,
       awaiting: nil,
       final: nil,
       kill_timer: nil
     }, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    executable = Application.get_env(:harness, :claude_executable, "claude")

    case System.find_executable(executable) do
      nil ->
        {:noreply, finalize(state, nil, "claude executable not found")}

      claude ->
        # stdin comes from /dev/null (the CLI otherwise pauses ~3s waiting on
        # the pipe); exec keeps the OS pid == the claude process, so SIGTERM
        # via os_pid still lands on the right process
        port =
          Port.open({:spawn_executable, "/bin/sh"}, [
            :binary,
            :exit_status,
            args: ["-c", ~s(exec "$0" "$@" < /dev/null), claude | CLIArgs.build(state.spec)],
            cd: state.spec.cwd,
            env: CLIArgs.env()
          ])

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        run =
          Runs.update_run!(state.run, %{
            status: "running",
            os_pid: os_pid,
            started_at: DateTime.utc_now()
          })

        Process.send_after(self(), :wall_clock_timeout, state.spec.timeout_ms)
        {:noreply, %{state | port: port, os_pid: os_pid, run: run}}
    end
  end

  @impl true
  def handle_call(:await, from, %{final: nil} = state), do: {:noreply, %{state | awaiting: from}}
  def handle_call(:await, _from, %{final: final} = state), do: {:stop, :normal, final, state}

  def handle_call({:kill, reason}, _from, state) do
    {:reply, :ok, do_kill(state, reason)}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {:noreply, ingest_chunk(state, chunk)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    {:noreply, finalize(drain_buffer(state), code, nil)}
  end

  def handle_info(:wall_clock_timeout, %{final: nil} = state) do
    Logger.warning("run #{state.run.id} hit wall-clock timeout, killing")
    {:noreply, do_kill(state, :timeout)}
  end

  def handle_info(:wall_clock_timeout, state), do: {:noreply, state}

  def handle_info(:sigkill_escalation, %{final: nil, os_pid: os_pid} = state)
      when is_integer(os_pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    {:noreply, state}
  end

  def handle_info(:sigkill_escalation, state), do: {:noreply, state}

  def handle_info(:shutdown, state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{final: nil} = state) do
    # daemon shutdown / crash while a session is live: signal the OS process
    # and finalize the row so no ghost "running" run survives the restart
    if is_integer(state.os_pid) do
      System.cmd("kill", ["-TERM", Integer.to_string(state.os_pid)], stderr_to_stdout: true)
    end

    try do
      Runs.update_run!(state.run, %{
        status: "killed",
        error: "daemon shutdown while run was live",
        ended_at: DateTime.utc_now()
      })
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- stream handling -------------------------------------------------------------

  # :json mode emits one JSON document — buffer everything, decode at exit.
  defp ingest_chunk(%{spec: %{output_mode: :json}} = state, chunk) do
    %{state | buffer: state.buffer <> chunk}
  end

  @max_busy_retries 3

  defp ingest_chunk(state, chunk) do
    {lines, rest} = split_lines(state.buffer <> chunk)
    do_ingest_with_retry(state, lines, rest, 0)
  end

  defp do_ingest_with_retry(state, lines, rest, attempt) do
    try do
      {:ok, new_state} =
        Repo.transaction(fn ->
          Enum.reduce(lines, %{state | buffer: rest}, &ingest_line(&2, &1))
        end)

      new_state
    rescue
      e in Exqlite.Error ->
        if String.contains?(Exception.message(e), "busy") and attempt < @max_busy_retries do
          Process.sleep(trunc(50 * :math.pow(2, attempt)))
          do_ingest_with_retry(state, lines, rest, attempt + 1)
        else
          Logger.error("run #{state.run.id} ingest batch failed: #{Exception.message(e)}")
          %{state | buffer: rest}
        end
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp ingest_line(state, line) do
    state = %{state | seq: state.seq + 1}

    case EventIngest.ingest(state.run, state.seq, line) do
      {:init, session_id} ->
        %{state | session_id: session_id}

      # a new API message id = a new turn; several assistant events can share
      # one message (one event per content block)
      {:turn, message_id} ->
        if message_id != nil and message_id == state.last_message_id do
          state
        else
          state = %{state | turns: state.turns + 1, last_message_id: message_id}

          if state.turns > state.spec.max_turns and is_nil(state.killed) do
            Logger.warning(
              "run #{state.run.id} exceeded turn cap #{state.spec.max_turns}, killing"
            )

            do_kill(state, :turn_cap)
          else
            state
          end
        end

      {:result, payload} ->
        %{state | result_payload: payload}

      {:overage, overage?} ->
        %{state | overage: state.overage or overage?}

      _other ->
        state
    end
  end

  # process whatever is left (final line without trailing newline; or the
  # whole document in :json mode)
  defp drain_buffer(%{spec: %{output_mode: :json}} = state) do
    case Jason.decode(String.trim(state.buffer)) do
      {:ok, %{} = payload} ->
        state = %{state | seq: state.seq + 1}
        {type, outcome} = EventIngest.categorize(payload)
        Runs.append_event!(state.run, state.seq, type, payload)

        case outcome do
          {:result, result} -> %{state | result_payload: result, buffer: ""}
          _ -> %{state | buffer: ""}
        end

      _ ->
        if String.trim(state.buffer) != "" do
          state = %{state | seq: state.seq + 1}

          Runs.append_event!(state.run, state.seq, "error", %{
            "raw" => String.slice(state.buffer, 0, 2_000),
            "note" => "unparseable json-mode output"
          })
        end

        %{state | buffer: ""}
    end
  end

  defp drain_buffer(state) do
    if String.trim(state.buffer) == "" do
      state
    else
      ingest_line(%{state | buffer: ""}, state.buffer)
    end
  end

  # -- kill + finalize ---------------------------------------------------------------

  defp do_kill(%{killed: nil} = state, reason) do
    if is_integer(state.os_pid) do
      System.cmd("kill", ["-TERM", Integer.to_string(state.os_pid)], stderr_to_stdout: true)
    end

    timer = Process.send_after(self(), :sigkill_escalation, @sigkill_after)
    %{state | killed: reason, kill_timer: timer}
  end

  defp do_kill(state, _reason), do: state

  defp finalize(%{final: nil} = state, exit_code, startup_error) do
    if state.kill_timer, do: Process.cancel_timer(state.kill_timer)

    {status, error, reply} = outcome(state, exit_code, startup_error)

    fields =
      EventIngest.result_fields(state.result_payload || %{})
      |> Map.put_new(:turns, state.turns)
      |> Map.put_new(:session_id, state.session_id)
      |> Map.merge(%{
        status: status,
        error: error,
        exit_code: exit_code,
        used_overage: state.overage,
        ended_at: DateTime.utc_now()
      })

    run = Runs.update_run!(state.run, fields)

    final =
      case reply do
        :ok ->
          payload = state.result_payload || %{}

          {:ok,
           %Runner.Result{
             run_id: run.id,
             subtype: run.result_subtype,
             structured_output: payload["structured_output"],
             result_text: payload["result"],
             session_id: run.session_id,
             turns: run.turns,
             tokens_in: run.tokens_in,
             tokens_out: run.tokens_out,
             cost: run.cost_estimate || 0.0,
             permission_denials: payload["permission_denials"] || []
           }}

        {:error, reason} ->
          {:error, reason}
      end

    case state.awaiting do
      nil ->
        %{state | final: final, run: run}

      from ->
        GenServer.reply(from, final)
        # stop after replying; the :via registration is released on exit
        send(self(), :shutdown)
        %{state | final: final, run: run, awaiting: nil}
    end
  end

  defp finalize(state, _exit_code, _startup_error), do: state

  defp outcome(state, exit_code, startup_error) do
    subtype = state.result_payload && state.result_payload["subtype"]

    cond do
      state.killed == :user ->
        {"killed", "killed by operator", {:error, :killed}}

      state.killed == :timeout ->
        {"killed", "wall-clock timeout", {:error, :timeout}}

      state.killed == :turn_cap ->
        {"killed", "exceeded Elixir-side turn cap", {:error, {:run_failed, :turn_cap}}}

      startup_error ->
        {"failed", startup_error, {:error, {:spawn_failed, startup_error}}}

      subtype == "success" ->
        {"succeeded", nil, :ok}

      is_binary(subtype) ->
        {"failed", "result subtype: #{subtype}", {:error, {:run_failed, subtype}}}

      true ->
        {"failed", "no result envelope (exit #{inspect(exit_code)})",
         {:error, {:cli_exit, exit_code}}}
    end
  end
end
