defmodule Flier.Entries do
  @moduledoc """
  Lazily stream directory entries using the native OS directory-reading API.

  Each element of the stream is a `%Flier.Entries.Entry{}` struct with three
  fields:

  - `:name` — The entry's file name as a string (not a full path).
  - `:type` — One of `:file`, `:directory`, `:symlink`, or `:other`.
  - `:path` — Relative path from the walk root to the directory containing the
    entry. Always `"."` in flat (non-recursive) mode.

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
    be opened (e.g. due to a permission error). `:skip` (default) silently
    continues the walk; `:raise` raises a `RuntimeError`. Only relevant when
    `recursive: true`.

  ## Returns

  A lazy `Stream` of `%Flier.Entries.Entry{}` structs.

  In flat mode the `:path` field of every entry is `"."`. In recursive mode
  `:path` holds the relative path from `path` to the directory containing the
  entry — `"."` for root-level entries, `"subdir"` for entries one level deep,
  etc.

  To build the full absolute path of an entry:

      full = Path.expand(Path.join([root, entry.path, entry.name]))

  Raises if `path` does not exist or cannot be opened.

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
    if Keyword.get(opts, :recursive, false) do
      stream_recursive(path, opts)
    else
      stream_flat(path)
    end
  end

  # ---------------------------------------------------------------------------
  # Flat (non-recursive) stream — original behaviour
  # ---------------------------------------------------------------------------

  defp stream_flat(path) do
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

  # ---------------------------------------------------------------------------
  # Recursive stream
  # ---------------------------------------------------------------------------

  defp stream_recursive(root, opts) do
    max_depth = Keyword.get(opts, :max_depth, :infinity)
    follow_symlinks = Keyword.get(opts, :follow_symlinks, false)
    on_error = Keyword.get(opts, :on_error, :skip)

    # State: stack of tagged frames.
    #   {:pending, abs_path, rel_path, depth} — directory not yet opened
    #   {:reading, ref, abs_path, rel_path, depth} — open handle, reading one entry at a time
    Stream.resource(
      fn -> [{:pending, root, ".", 0}] end,
      fn
        [] ->
          {:halt, []}

        [{:pending, dir, rel_path, depth} | rest] ->
          case Flier.Entries.Native.opendir(dir) do
            {:error, reason} ->
              case on_error do
                :skip ->
                  {[], rest}

                :raise ->
                  raise "Flier.Entries.stream/2: cannot open directory #{inspect(dir)}: #{reason}"
              end

            {:ok, ref} ->
              # Transition to :reading — no entry emitted yet
              {[], [{:reading, ref, dir, rel_path, depth} | rest]}
          end

        [{:reading, ref, dir, rel_path, depth} | rest] ->
          case Flier.Entries.Native.readdir(ref) do
            {:error, _} ->
              # End of directory (or read error) — close handle and pop frame
              Flier.Entries.Native.closedir(ref)
              {[], rest}

            {:ok, entry} ->
              tagged = %{entry | path: rel_path}

              stack_tail = [{:reading, ref, dir, rel_path, depth} | rest]

              new_stack =
                if (max_depth == :infinity or depth < max_depth) and
                     (entry.type == :directory or (follow_symlinks and entry.type == :symlink)) do
                  sub_abs = Path.join(dir, entry.name)

                  sub_rel =
                    if rel_path == ".", do: entry.name, else: Path.join(rel_path, entry.name)

                  # Push subdir as :pending on top of current :reading frame (DFS)
                  [{:pending, sub_abs, sub_rel, depth + 1} | stack_tail]
                else
                  stack_tail
                end

              {[tagged], new_stack}
          end
      end,
      fn stack ->
        # Close any dir handles still open when the stream is halted early
        Enum.each(stack, fn
          {:reading, ref, _, _, _} -> Flier.Entries.Native.closedir(ref)
          {:pending, _, _, _} -> :ok
        end)
      end
    )
  end
end
