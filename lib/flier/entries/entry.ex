defmodule Flier.Entries.Entry do
  @moduledoc """
  Represents a single entry returned by `Flier.Entries.stream/2`.

  ## Fields

  - `:name` — The file name of the entry as a string (not a full path).
  - `:type` — The kind of file-system object. One of:
    - `:file` — A regular file.
    - `:directory` — A directory.
    - `:symlink` — A symbolic link.
    - `:other` — Any other file-system object (device node, socket, FIFO, etc.).
  - `:path` — The relative path from the walk root to the **directory containing**
    this entry. Always `"."` in flat (non-recursive) mode. In recursive mode, `"."`
    for root-level entries and `"subdir/nested"` for deeper entries.

    To build the full absolute path:

        Path.expand(Path.join([root, entry.path, entry.name]))

  """

  defstruct [:name, :type, path: "."]
end
