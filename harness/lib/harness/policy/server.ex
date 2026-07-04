defmodule Harness.Policy.Server do
  @moduledoc """
  Owns the parsed policy. The current `%Schema{}` lives in `:persistent_term`
  so `Policy.get/0` is a lock-free read on every worker's hot path.

  On reload, a parse/validation failure keeps the previous good policy and
  broadcasts `{:policy_error, errors}` on the `"policy"` topic; success
  broadcasts `{:policy_reloaded, policy}`.
  """

  use GenServer
  require Logger

  alias Harness.Policy.Schema

  @pt_key {__MODULE__, :policy}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec current() :: Schema.t()
  def current, do: :persistent_term.get(@pt_key)

  @spec reload() :: :ok | {:error, [String.t()]}
  def reload, do: GenServer.call(__MODULE__, :reload)

  @impl true
  def init(_opts) do
    case load() do
      {:ok, policy} ->
        :persistent_term.put(@pt_key, policy)
        {:ok, %{}}

      {:error, errors} ->
        {:stop, {:invalid_policy, errors}}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case load() do
      {:ok, policy} ->
        :persistent_term.put(@pt_key, policy)
        Logger.info("policy reloaded from #{path()}")
        broadcast({:policy_reloaded, policy})
        {:reply, :ok, state}

      {:error, errors} ->
        Logger.error("policy reload failed, keeping previous policy: #{inspect(errors)}")
        broadcast({:policy_error, errors})
        {:reply, {:error, errors}, state}
    end
  end

  defp load do
    with {:ok, raw} <- read_yaml(path()) do
      Schema.parse(raw)
    end
  end

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, ["#{path}: #{Exception.message(reason)}"]}
    end
  rescue
    e -> {:error, ["#{path}: #{Exception.message(e)}"]}
  end

  defp path, do: Application.fetch_env!(:harness, :policy_path)

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Harness.PubSub, "policy", message)
  end
end
