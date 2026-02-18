defmodule Flier.Entries.Entry do
  @moduledoc """
  Represents a single entry returned by `Flier.Entries.stream/1`.

  ## Fields

  - `:name` — The file name of the entry as a string (not a full path).
  - `:type` — The kind of file-system object. One of:
    - `:file` — A regular file.
    - `:directory` — A directory.
    - `:symlink` — A symbolic link.
    - `:other` — Any other file-system object (device node, socket, FIFO, etc.).
  """

  defstruct [:name, :type]
end
