defmodule Flier.Inotify do
  @moduledoc false

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

  def start_watcher(path, mask, pid \\ self())

  def start_watcher(path, :all, pid), do: Flier.Inotify.Native.start_watcher(path, @all, pid)

  def start_watcher(path, mask, pid),
    do: Flier.Inotify.Native.start_watcher(path, mask, pid)

  def stop_watcher(ref), do: Flier.Inotify.Native.stop_watcher(ref)

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
