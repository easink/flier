defmodule Flier.Inotify.Event do
  @moduledoc """
  An inotify event, as delivered by `Flier.Inotify.start_watcher/3` in
  `{:inotify_event, ref, event}` messages and emitted by
  `Flier.Inotify.stream/2`.

  ## Fields

  - `:name` — The name of the file the event is about, relative to the
    watched directory, as a binary of the raw bytes from the kernel. Empty
    (`""`) for events on the watched directory itself and for `:q_overflow`.
  - `:masks` — The event and flag atoms set on the event, for example
    `[:create, :isdir]`. See `Flier.Inotify` for the possible values.
  - `:cookie` — Links the `:moved_from` and `:moved_to` events of a single
    rename: both carry the same non-zero cookie. `0` for all other events.

  ## Example

      receive do
        {:inotify_event, ^ref, %Flier.Inotify.Event{masks: [:moved_from], cookie: cookie} = from} ->
          receive do
            {:inotify_event, ^ref, %Flier.Inotify.Event{masks: [:moved_to], cookie: ^cookie} = to} ->
              {:renamed, from.name, to.name}
          after
            # The destination is outside the watched directory.
            100 -> {:moved_away, from.name}
          end
      end
  """

  @enforce_keys [:name, :masks, :cookie]
  defstruct [:name, :masks, :cookie]

  @type t :: %__MODULE__{
          name: binary(),
          masks: [atom()],
          cookie: non_neg_integer()
        }
end
