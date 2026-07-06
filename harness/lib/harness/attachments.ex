defmodule Harness.Attachments do
  @moduledoc """
  Shared upload handling for the LiveView attachment pickers (Compose,
  Ideation). Previously duplicated verbatim between `ComposeLive` and
  `IdeationLive` — see issue #83.
  """

  import Phoenix.LiveView, only: [consume_uploaded_entries: 3]
  import Phoenix.Component, only: [upload_errors: 2]

  @allowed_exts ~w(.png .jpg .jpeg .gif .webp .txt .md .log .pdf .diff .patch)

  @max_entries 5
  @max_file_size 15_000_000

  def allowed_exts, do: @allowed_exts

  @doc "Options for `allow_upload/3`, shared by every LiveView that accepts attachments."
  def upload_opts do
    [accept: @allowed_exts, max_entries: @max_entries, max_file_size: @max_file_size]
  end

  @doc """
  Consumes every entry uploaded under `upload_name`, copying each into `dir`
  (created if needed) under a sanitized filename, and returns the persisted
  `[%{filename:, path:, content_type:}]` list.
  """
  def persist_uploaded_entries(socket, upload_name, dir) do
    File.mkdir_p!(dir)

    consume_uploaded_entries(socket, upload_name, fn %{path: tmp_path}, entry ->
      # client_name is browser-supplied — strip any path components so a name
      # like "../../../x.png" can't escape dir on cp, and so the stored
      # filename can't forge prompt trust-boundary markers downstream.
      filename = safe_filename(entry.client_name)
      dest = Path.join(dir, filename)
      File.cp!(tmp_path, dest)
      {:ok, %{filename: filename, path: dest, content_type: entry.client_type}}
    end)
  end

  # Reduce a client-supplied filename to a single safe path segment. basename
  # drops directory components (defeating ../ traversal); we then reject any
  # residual separators or empty/dot-only names, falling back to a stable name.
  def safe_filename(client_name) do
    name = client_name |> to_string() |> Path.basename() |> String.trim()

    if name in ["", ".", ".."] or String.contains?(name, ["/", "\\"]) do
      "attachment"
    else
      name
    end
  end

  @doc "`[{entry, error}]` pairs for every entry-scoped upload error."
  def entry_errors(uploads) do
    Enum.flat_map(uploads.entries, fn entry ->
      Enum.map(upload_errors(uploads, entry), &{entry, &1})
    end)
  end

  def upload_error_message(:too_large),
    do: "file is too large (max #{div(@max_file_size, 1_000_000)} MB)"

  def upload_error_message(:too_many_files), do: "too many files (max #{@max_entries})"
  def upload_error_message(:not_accepted), do: "unsupported file type"
  def upload_error_message(other), do: to_string(other)

  @doc "Whether a client-supplied MIME type is an image, for thumbnail previews."
  def image?(content_type) when is_binary(content_type),
    do: String.starts_with?(content_type, "image/")

  def image?(_), do: false
end
