defmodule Flier.Inotify.Watcher do
  @moduledoc """
  A running inotify watcher, returned by `Flier.Inotify.start_watcher/3`.

  The `:ref` field is a unique reference included in every event message the
  watcher sends, so events can be matched to their watcher:

      {:ok, %Flier.Inotify.Watcher{ref: ref} = watcher} =
        Flier.Inotify.start_watcher("/tmp", [:create])

      receive do
        {:inotify_event, ^ref, %Flier.Inotify.Event{} = event} -> event
      end

  All other fields are private. The watcher is stopped automatically when the
  struct is garbage-collected, or explicitly with `Flier.Inotify.stop_watcher/1`.
  """

  @enforce_keys [:ref, :resource]
  defstruct [:ref, :resource]

  @type t :: %__MODULE__{ref: reference(), resource: reference()}

  defimpl Inspect do
    def inspect(%{ref: ref}, opts) do
      Inspect.Algebra.concat(["#Flier.Inotify.Watcher<", Inspect.inspect(ref, opts), ">"])
    end
  end
end
