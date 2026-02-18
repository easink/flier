defmodule Flier do
  @moduledoc """
  Flier exposes low-level Linux file-system functionality to Elixir via
  Rustler NIFs (Native Implemented Functions written in Rust).

  It provides two main capabilities:

  - **`Flier.Inotify`** — Watch a directory for file-system events (create,
    modify, delete, rename, open, close, access, attribute changes, etc.)
    using the Linux `inotify` kernel subsystem.

  - **`Flier.Entries`** — Lazily stream the contents of a directory as
    `%Flier.Entries.Entry{}` structs, using the native OS directory-reading
    API.

  Both APIs are `Stream`-compatible, making them composable with the standard
  `Enum` and `Stream` pipeline patterns.

  ## Requirements

  Flier requires Linux (it depends on `inotify`, which is Linux-specific) and
  a Rust toolchain at compile time (via [Rustler](https://github.com/rusterlium/rustler)).

  ## Quick start

      # Watch /tmp for file creations
      "/tmp"
      |> Flier.Inotify.stream([:create])
      |> Stream.each(fn {file, masks} ->
        IO.puts("Created: \#{file} (masks: \#{inspect(masks)})")
      end)
      |> Stream.run()

      # List all entries in a directory
      "/tmp"
      |> Flier.Entries.stream()
      |> Enum.each(fn entry ->
        IO.puts("\#{entry.name} (\#{entry.type})")
      end)

  See `Flier.Inotify` and `Flier.Entries` for full API documentation.
  """
end
