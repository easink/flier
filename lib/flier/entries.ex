defmodule Flier.Entries do
  @moduledoc """
  Lazily stream directory entries using the native OS directory-reading API.

  Each element of the stream is a `%Flier.Entries.Entry{}` struct with two
  fields:

  - `:name` — The entry's file name as a string (not a full path).
  - `:type` — One of `:file`, `:directory`, `:symlink`, or `:other`.

  The stream reads entries on demand, so arbitrarily large directories can be
  processed without loading all entries into memory at once.

  ## Examples

      # Print every entry in /tmp
      "/tmp"
      |> Flier.Entries.stream()
      |> Enum.each(fn entry ->
        IO.puts("\#{entry.name} (\#{entry.type})")
      end)

      # Collect only regular files
      files =
        "/home/user/documents"
        |> Flier.Entries.stream()
        |> Stream.filter(fn entry -> entry.type == :file end)
        |> Enum.map(& &1.name)
  """

  @doc """
  Returns a lazy `Stream` of directory entries for `path`.

  Entries are read one at a time from the OS using the native directory API.
  The underlying directory handle is opened when enumeration starts and closed
  automatically when the stream is halted or fully consumed.

  The order in which entries are returned is determined by the operating
  system (typically creation order on Linux). The special entries `.` and `..`
  are **not** included in the stream.

  ## Parameters

  - `path` — Absolute or relative path to the directory to read.

  ## Returns

  A lazy `Stream` of `%Flier.Entries.Entry{}` structs.

  Raises if `path` does not exist or cannot be opened.

  ## Examples

      Flier.Entries.stream("/tmp") |> Enum.to_list()
      #=> [
      #=>   %Flier.Entries.Entry{name: "foo.txt", type: :file},
      #=>   %Flier.Entries.Entry{name: "bar", type: :directory},
      #=>   ...
      #=> ]

      # Count entries in a directory
      "/usr/bin" |> Flier.Entries.stream() |> Enum.count()
  """
  @spec stream(path :: String.t()) :: Enumerable.t()
  def stream(path) do
    Stream.resource(
      fn ->
        {:ok, ref} = Flier.Entries.Native.opendir(path)
        ref
      end,
      fn ref ->
        case Flier.Entries.Native.readdir(ref) do
          {:ok, entry} -> {[entry], ref}
          {:error, _reason} -> {:halt, ref}
        end
      end,
      fn ref -> Flier.Entries.Native.closedir(ref) end
    )
  end
end
