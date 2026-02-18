defmodule Flier.Inotify do
  @moduledoc """
  Watch directories for file-system events using the Linux `inotify` subsystem.

  This module provides two usage styles:

  1. **Message-based** — Start a watcher with `start_watcher/2,3`, receive
     `{:inotify_event, filename, masks}` messages in a process, then stop
     the watcher with `stop_watcher/1`.

  2. **Stream-based** — Use `stream/2` to get a lazy `Stream` of
     `{filename, masks}` tuples. The underlying watcher is started and
     stopped automatically.

  ## Event masks

  The following atoms can be used as event masks:

  | Atom | Description |
  |------|-------------|
  | `:create` | A file or directory was created |
  | `:modify` | A file was modified |
  | `:delete` | A file or directory was deleted |
  | `:moved_from` | A file was moved out of the watched directory |
  | `:moved_to` | A file was moved into the watched directory |
  | `:access` | A file was accessed (read) |
  | `:close_write` | A file opened for writing was closed |
  | `:close_nowrite` | A file opened read-only was closed |
  | `:open` | A file or directory was opened |
  | `:attrib` | File metadata (permissions, timestamps, etc.) changed |
  | `:ignored` | The watch was removed (directory deleted or unmounted) |
  | `:isdir` | Included in the event when the subject is a directory |

  Pass the special atom `:all` as the mask to subscribe to all of the above
  events at once.

  ## Examples

  ### Message-based usage

      {:ok, ref} = Flier.Inotify.start_watcher("/tmp", [:create, :delete])

      receive do
        {:inotify_event, file, masks} ->
          IO.puts("Event on \#{file}: \#{inspect(masks)}")
      end

      :stopped = Flier.Inotify.stop_watcher(ref)

  ### Stream-based usage

      "/tmp"
      |> Flier.Inotify.stream([:close_write])
      |> Stream.each(fn {file, masks} ->
        IO.puts("\#{file} was written and closed (masks: \#{inspect(masks)})")
      end)
      |> Stream.run()
  """

  @all [
    :create,
    :modify,
    :delete,
    :moved_from,
    :moved_to,
    :access,
    :close_write,
    :close_nowrite,
    :open,
    :attrib,
    :ignored,
    :isdir
  ]

  @doc """
  Starts an inotify watcher on `path` for the given event `mask`.

  Spawns a background OS thread that polls for inotify events and sends
  `{:inotify_event, filename, masks}` messages to `pid` as they occur.

  ## Parameters

  - `path` — Absolute path to the directory to watch.
  - `mask` — A list of event atoms to subscribe to (see module docs for the
    full list), or the atom `:all` to subscribe to every event type.
  - `pid` — The process to deliver events to. Defaults to `self()`.

  ## Returns

  - `{:ok, ref}` — A reference to the watcher resource. Pass this to
    `stop_watcher/1` when done.
  - `{:error, reason}` — If the path does not exist or is not watchable.

  ## Examples

      {:ok, ref} = Flier.Inotify.start_watcher("/tmp", [:create])
      {:ok, ref} = Flier.Inotify.start_watcher("/tmp", :all)
      {:ok, ref} = Flier.Inotify.start_watcher("/tmp", [:modify], some_pid)
  """
  @spec start_watcher(path :: String.t(), [atom()] | :all, pid()) ::
          {:ok, reference()} | {:error, term()}
  def start_watcher(path, mask, pid \\ self())

  def start_watcher(path, :all, pid), do: Flier.Inotify.Native.start_watcher(path, @all, pid)

  def start_watcher(path, mask, pid),
    do: Flier.Inotify.Native.start_watcher(path, mask, pid)

  @doc """
  Stops a running inotify watcher.

  Signals the background OS thread to stop, waits for it to terminate, and
  releases the underlying inotify file descriptor.

  The watcher resource is also stopped automatically when the reference is
  garbage-collected by the BEAM.

  ## Parameters

  - `ref` — The reference returned by `start_watcher/2,3`.

  ## Returns

  `:stopped`

  ## Examples

      {:ok, ref} = Flier.Inotify.start_watcher("/tmp", [:create])
      :stopped = Flier.Inotify.stop_watcher(ref)
  """
  @spec stop_watcher(reference()) :: :stopped
  def stop_watcher(ref), do: Flier.Inotify.Native.stop_watcher(ref)

  @doc """
  Returns a lazy `Stream` of inotify events from `path`.

  Each element emitted by the stream is a `{filename, masks}` tuple, where
  `filename` is a string and `masks` is a list of event atoms.

  The stream starts a watcher when enumeration begins and stops it when the
  stream is halted or the enumerating process exits. The stream is infinite
  by default — use `Stream.take/2`, `Enum.take/2`, or similar to bound it.

  > #### Blocking {: .warning}
  >
  > Enumerating this stream blocks the calling process until an event arrives.
  > Run it in a dedicated process (e.g., with `Task.start/1`) if you need to
  > keep the caller responsive.

  ## Parameters

  - `path` — Absolute path to the directory to watch.
  - `mask` — A list of event atoms (see module docs), or `:all`. Defaults to
    all supported event types.

  ## Examples

      # Collect the next 5 write events in /tmp
      "/tmp"
      |> Flier.Inotify.stream([:close_write])
      |> Enum.take(5)
      |> Enum.each(fn {file, masks} -> IO.inspect({file, masks}) end)

      # Run indefinitely in a task
      Task.start(fn ->
        "/var/log"
        |> Flier.Inotify.stream([:modify])
        |> Stream.each(fn {file, _masks} -> IO.puts("Modified: \#{file}") end)
        |> Stream.run()
      end)
  """
  @spec stream(path :: String.t(), [atom()] | :all) :: Enumerable.t()
  def stream(path, mask \\ @all) do
    Stream.resource(
      fn ->
        {:ok, ref} = Flier.Inotify.start_watcher(path, mask)
        ref
      end,
      fn ref ->
        receive do
          {:inotify_event, file, mask} -> {[{file, mask}], ref}
        end

        # after
        #   5000 -> {:halt, ref}
      end,
      fn ref -> Flier.Inotify.stop_watcher(ref) end
    )
  end
end
