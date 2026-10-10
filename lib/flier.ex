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

  Flier requires Linux (it depends on `inotify`, which is Linux-specific).

  Precompiled NIFs are downloaded at compile time (via
  [RustlerPrecompiled](https://github.com/philss/rustler_precompiled)) for
  these targets, so no Rust toolchain is needed on them:

  - `x86_64-unknown-linux-gnu`
  - `aarch64-unknown-linux-gnu`
  - `arm-unknown-linux-gnueabihf`
  - `riscv64gc-unknown-linux-gnu`

  ### Building from source

  On other targets (for example musl), or to build the NIFs yourself, set the
  `FLIER_BUILD` environment variable to `1` or `true` and add `:rustler` to
  your dependencies, since it is an optional dependency of Flier:

      {:rustler, ">= 0.0.0", optional: true}

  This needs a Rust toolchain. Then recompile Flier:

      FLIER_BUILD=1 mix deps.compile flier --force

  ## Quick start

      # Watch /tmp for file creations
      "/tmp"
      |> Flier.Inotify.stream([:create])
      |> Stream.each(fn event ->
        IO.puts("Created: \#{event.name} (masks: \#{inspect(event.masks)})")
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
