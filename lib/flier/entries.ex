defmodule Flier.Entries do
  @moduledoc """
  Lazily stream directory entries using the native OS directory-reading API.

  Each element of the stream is a `%Flier.Entries.Entry{}` struct with three
  fields:

  - `:name` — The entry's file name (not a full path).
  - `:type` — One of `:file`, `:directory`, `:symlink`, or `:other`.
  - `:path` — Relative path from the walk root to the directory containing the
    entry. Always `"."` in flat (non-recursive) mode.

  The stream reads entries on demand, so arbitrarily large directories can be
  processed without loading all entries into memory at once.

  > #### Filename encoding {: .info}
  >
  > Names (and the `:path` of entries below them) are binaries containing the
  > raw bytes from the OS. Most are valid UTF-8 and can be used as ordinary
  > Elixir strings. Names that are not valid UTF-8 (legal on Linux) keep every
  > byte intact and can be passed back to file APIs unchanged, including as the
  > `path` argument of `stream/2`.

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

      # Recursive walk
      "/home/user/projects"
      |> Flier.Entries.stream(recursive: true)
      |> Stream.filter(fn entry -> entry.type == :file end)
      |> Enum.map(fn entry ->
        Path.expand(Path.join(["/home/user/projects", entry.path, entry.name]))
      end)
  """

  @doc """
  Returns a lazy `Stream` of directory entries for `path`.

  ## Parameters

  - `path` — Absolute or relative path to the directory to read.
  - `opts` — Keyword options (see below).

  ## Options

  - `recursive: boolean` — When `true`, descends into subdirectories depth-first.
    Defaults to `false`.

  - `max_depth: non_neg_integer() | :infinity` — Maximum recursion depth. `0`
    means only the entries in `path` itself (equivalent to non-recursive), `1`
    means `path` plus one level of subdirectories, and so on. Only relevant when
    `recursive: true`. Defaults to `:infinity`.

  - `follow_symlinks: boolean` — When `true`, symbolic links that point to
    directories are descended into during a recursive walk. When `false`
    (default), symlinked directories are yielded as entries but not recursed
    into. Only relevant when `recursive: true`. Note: enabling this without a
    `max_depth` guard may cause infinite loops if the directory tree contains
    symlink cycles.

  - `on_error: :skip | :raise` — Controls behaviour when a subdirectory cannot
    be opened (e.g. due to a permission error) or reading it fails midway. `:skip` (default) silently
    continues the walk; `:raise` raises a `RuntimeError`. Only relevant when
    `recursive: true`. Failing to open or read the root `path` always raises.

  ## Returns

  A lazy `Stream` of `%Flier.Entries.Entry{}` structs.

  In flat mode the `:path` field of every entry is `"."`. In recursive mode
  `:path` holds the relative path from `path` to the directory containing the
  entry — `"."` for root-level entries, `"subdir"` for entries one level deep,
  etc.

  To build the full absolute path of an entry:

      full = Path.expand(Path.join([root, entry.path, entry.name]))

  Raises a `RuntimeError` when the stream is enumerated if `path` does not
  exist or cannot be opened, regardless of `:on_error`.

  ## Examples

      # Flat listing
      Flier.Entries.stream("/tmp") |> Enum.to_list()

      # Recursive listing
      Flier.Entries.stream("/home/user", recursive: true) |> Enum.to_list()

      # Recursive, limited to two levels deep
      Flier.Entries.stream("/home/user", recursive: true, max_depth: 2)
      |> Enum.to_list()

      # Recursive, follow symlinked dirs (use max_depth to guard against cycles)
      Flier.Entries.stream("/home/user", recursive: true, follow_symlinks: true, max_depth: 10)
      |> Enum.to_list()

      # Count entries in a directory
      "/usr/bin" |> Flier.Entries.stream() |> Enum.count()
  """
  @spec stream(path :: String.t(), opts :: keyword()) :: Enumerable.t()
  def stream(path, opts \\ []) do
    walk =
      if Keyword.get(opts, :recursive, false) do
        %{
          max_depth: Keyword.get(opts, :max_depth, :infinity),
          follow_symlinks: Keyword.get(opts, :follow_symlinks, false),
          on_error: Keyword.get(opts, :on_error, :skip)
        }
      else
        # A flat listing is a walk that never descends.
        %{max_depth: 0, follow_symlinks: false, on_error: :raise}
      end

    Stream.resource(
      fn -> [{:pending, path, ".", 0}] end,
      &next(&1, walk),
      &close_all/1
    )
  end

  # The state is a depth-first stack of frames:
  #   {:pending, dir, rel_path, depth}       — directory not yet opened
  #   {:reading, ref, dir, rel_path, depth}  — open handle, read one entry per step
  defp next([], _walk), do: {:halt, []}

  defp next([{:pending, dir, rel_path, depth} | rest], walk) do
    case Flier.Entries.Native.opendir(dir) do
      {:ok, ref} ->
        {[], [{:reading, ref, dir, rel_path, depth} | rest]}

      # The root must always be readable; on_error only governs subdirectories.
      {:error, reason} when depth == 0 or walk.on_error == :raise ->
        raise_error("open", dir, reason)

      {:error, _reason} ->
        {[], rest}
    end
  end

  defp next([{:reading, ref, dir, rel_path, depth} = frame | rest], walk) do
    case Flier.Entries.Native.readdir(ref) do
      {:ok, entry} ->
        stack = [frame | rest]

        stack =
          if depth_allowed?(depth, walk.max_depth) and
               descend?(entry.type, dir, entry.name, walk.follow_symlinks) do
            [
              {:pending, Path.join(dir, entry.name), sub_path(rel_path, entry.name), depth + 1}
              | stack
            ]
          else
            stack
          end

        {[%{entry | path: rel_path}], stack}

      {:error, :end_of_directory} ->
        Flier.Entries.Native.closedir(ref)
        {[], rest}

      {:error, reason} ->
        Flier.Entries.Native.closedir(ref)
        if depth == 0 or walk.on_error == :raise, do: raise_error("read", dir, reason)
        {[], rest}
    end
  end

  # Close any directory handles still open when the stream halts early.
  defp close_all(stack) do
    for {:reading, ref, _, _, _} <- stack, do: Flier.Entries.Native.closedir(ref)
    :ok
  end

  defp depth_allowed?(_depth, :infinity), do: true
  defp depth_allowed?(depth, max_depth), do: depth < max_depth

  # Only descend into real directories, or symlinks whose target is a
  # directory (broken links and links to files are yielded but not followed).
  defp descend?(:directory, _dir, _name, _follow_symlinks), do: true
  defp descend?(:symlink, dir, name, true), do: File.dir?(Path.join(dir, name))
  defp descend?(_type, _dir, _name, _follow_symlinks), do: false

  defp sub_path(".", name), do: name
  defp sub_path(rel_path, name), do: Path.join(rel_path, name)

  defp raise_error(action, path, reason) do
    raise "Flier.Entries.stream/2: cannot #{action} directory #{inspect(path)}: #{reason}"
  end
end
