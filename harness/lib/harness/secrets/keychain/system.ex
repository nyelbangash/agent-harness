defmodule Harness.Secrets.Keychain.System do
  @moduledoc "Reads the real macOS login Keychain via `security(1)`."

  @behaviour Harness.Secrets.Keychain

  @impl true
  def find_generic_password(service, account) do
    args =
      ["find-generic-password", "-s", service] ++
        case account do
          nil -> []
          account -> ["-a", account]
        end ++ ["-w"]

    case System.cmd("security", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim_trailing(output, "\n")}
      {_output, _} -> {:error, :not_found}
    end
  end
end
