defmodule Flier.Inotify do
  @moduledoc """
  Watch directories for file-system events using the Linux `inotify` subsystem.

  This module provides two usage styles:

  1. **Message-based** — Start a watcher with `start_watcher/2,3`, receive
     `{:inotify_event, ref, filename, masks}` messages in a process, then stop
     the watcher with `stop_watcher/1`. `ref` is the watcher's
     `Flier.Inotify.Watcher` `:ref`, so events from several watchers in one
     process can be told apart.

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

  Pass the special atom `:all` as the mask to subscribe to all of the above
  events at once. Unknown atoms raise an `ArgumentError`.

  Events may additionally carry these flags, which are always reported by the
  kernel and do not need to be subscribed to (they are accepted in a mask but
  have no effect):

  | Atom | Description |
  |------|-------------|
  | `:ignored` | The watch was removed (directory deleted or unmounted). No further events follow. |
  | `:isdir` | The subject of the event is a directory |

  > #### Filename encoding {: .info}
  >
  > Filenames are delivered as binaries containing the raw bytes from the
  > kernel. Most filenames are valid UTF-8 and can be used as ordinary
  > Elixir strings. Filenames that are not valid UTF-8 (legal on Linux) are
  > still delivered with every byte intact and can be passed to file APIs
  > unchanged, but may not display correctly with `IO.puts/1` and similar.

  ## Examples

  ### Message-based usage

      {:ok, %Flier.Inotify.Watcher{ref: ref} = watcher} =
        Flier.Inotify.start_watcher("/tmp", [:create, :delete])

      receive do
        {:inotify_event, ^ref, file, masks} ->
          IO.puts("Event on \#{file}: \#{inspect(masks)}")
      end

      :stopped = Flier.Inotify.stop_watcher(watcher)

  ### Stream-based usage

      "/tmp"
      |> Flier.Inotify.stream([:close_write])
      |> Stream.each(fn {file, masks} ->
        IO.puts("\#{file} was written and closed (masks: \#{inspect(masks)})")
      end)
      |> Stream.run()
  """

  alias Flier.Inotify.Watcher

  @events [
    :create,
    :modify,
    :delete,
    :moved_from,
    :moved_to,
    :access,
    :close_write,
    :close_nowrite,
    :open,
    :attrib
  ]

  # Flags the kernel reports on its own; accepted in a mask but have no effect.
  @report_only [:ignored, :isdir]

  @doc """
  Starts an inotify watcher on `path` for the given event `mask`.

  Spawns a background OS thread that reads inotify events and sends
  `{:inotify_event, ref, filename, masks}` messages to `pid` as they occur,
  where `ref` is the returned watcher's `:ref`.

  ## Parameters

  - `path` — Absolute path to the directory to watch.
  - `mask` — A list of event atoms to subscribe to (see module docs for the
    full list), or the atom `:all` to subscribe to every event type. Raises
    `ArgumentError` for unknown atoms or when no subscribable event is given.
  - `pid` — The process to deliver events to. Defaults to `self()`.

  ## Returns

  - `{:ok, watcher}` — A `Flier.Inotify.Watcher` struct. Match events on its
    `:ref` field and pass it to `stop_watcher/1` when done.
  - `{:error, reason}` — If the path does not exist or is not watchable.

  ## Examples

      {:ok, watcher} = Flier.Inotify.start_watcher("/tmp", [:create])
      {:ok, watcher} = Flier.Inotify.start_watcher("/tmp", :all)
      {:ok, watcher} = Flier.Inotify.start_watcher("/tmp", [:modify], some_pid)
  """
  @spec start_watcher(path :: String.t(), [atom()] | :all, pid()) ::
          {:ok, Watcher.t()} | {:error, term()}
  def start_watcher(path, mask, pid \\ self()) do
    mask = validate_mask!(mask)
    ref = make_ref()

    case Flier.Inotify.Native.start_watcher(path, mask, pid, ref) do
      {:ok, resource} -> {:ok, %Watcher{ref: ref, resource: resource}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_mask!(:all), do: @events

  defp validate_mask!(mask) when is_list(mask) do
    case Enum.reject(mask, &(&1 in @events or &1 in @report_only)) do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown inotify event(s): #{inspect(unknown)}"
    end

    if not Enum.any?(mask, &(&1 in @events)) do
      raise ArgumentError,
            "inotify mask must contain at least one event of #{inspect(@events)}, got: #{inspect(mask)}"
    end

    mask
  end

  defp validate_mask!(mask) do
    raise ArgumentError, "inotify mask must be a list of events or :all, got: #{inspect(mask)}"
  end

  @doc """
  Stops a running inotify watcher.

  Signals the background OS thread to stop, waits for it to terminate, and
  releases the underlying inotify file descriptor.

  The watcher is also stopped automatically when it is garbage-collected by
  the BEAM. Events already delivered to the mailbox are not removed.

  ## Parameters

  - `watcher` — The `Flier.Inotify.Watcher` returned by `start_watcher/2,3`.

  ## Returns

  `:stopped`

  ## Examples

      {:ok, watcher} = Flier.Inotify.start_watcher("/tmp", [:create])
      :stopped = Flier.Inotify.stop_watcher(watcher)
  """
  @spec stop_watcher(Watcher.t()) :: :stopped
  def stop_watcher(%Watcher{resource: resource}),
    do: Flier.Inotify.Native.stop_watcher(resource)

  @doc """
  Returns a lazy `Stream` of inotify events from `path`.

  Each element emitted by the stream is a `{filename, masks}` tuple, where
  `filename` is a string and `masks` is a list of event atoms.

  The stream starts a watcher when enumeration begins and stops it when the
  stream is halted or the enumerating process exits. On halt, any of its
  events still in the mailbox are discarded; events from other watchers are
  left untouched. The stream is infinite
  by default — use `Stream.take/2`, `Enum.take/2`, or similar to bound it.
  It ends on its own only when the watch is removed by the kernel (e.g. the
  watched directory is deleted or unmounted), after emitting the final event
  carrying the `:ignored` flag.

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
  def stream(path, mask \\ :all) do
    Stream.resource(
      fn ->
        {:ok, watcher} = start_watcher(path, mask)
        {watcher, :running}
      end,
      &next_event/1,
      fn {%Watcher{ref: ref} = watcher, _status} ->
        stop_watcher(watcher)
        flush_events(ref)
      end
    )
  end

  defp next_event({_watcher, :done} = state), do: {:halt, state}

  defp next_event({%Watcher{ref: ref} = watcher, :running}) do
    receive do
      {:inotify_event, ^ref, file, masks} ->
        # :ignored means the watch is gone; no further events can follow.
        status = if :ignored in masks, do: :done, else: :running
        {[{file, masks}], {watcher, status}}
    end
  end

  # The watcher thread is joined by stop_watcher/1, so no events for `ref`
  # can arrive after this runs.
  defp flush_events(ref) do
    receive do
      {:inotify_event, ^ref, _file, _masks} -> flush_events(ref)
    after
      0 -> :ok
    end
  end
end
