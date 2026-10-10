# Flier

Linux file-system helpers for Elixir, implemented as Rust NIFs:

- **`Flier.Inotify`** — watch a directory for events (create, modify,
  delete, move, open, close, access, attribute changes) via `inotify`, as
  messages or as a `Stream`.
- **`Flier.Entries`** — lazily stream the entries of a directory, flat or
  recursively, with their file type.

Flier is Linux-only. Precompiled NIFs are provided for x86_64, aarch64,
32-bit ARM (gnueabihf) and riscv64 glibc targets, so no Rust toolchain is
needed.

## Installation

``` elixir
def deps do
  [
    {:flier, "~> 0.6.0"}
  ]
end
```

To build the NIFs from source instead (for example on musl), see
"Building from source" in the `Flier` module docs.

## Watching a directory

Messages are tagged with the watcher's `ref`, so several watchers can share
a process:

``` elixir
{:ok, %Flier.Inotify.Watcher{ref: ref} = watcher} =
  Flier.Inotify.start_watcher("/tmp", [:create, :delete])

receive do
  {:inotify_event, ^ref, %Flier.Inotify.Event{name: name, masks: masks}} ->
    IO.puts("#{name}: #{inspect(masks)}")
end

:stopped = Flier.Inotify.stop_watcher(watcher)
```

Or as a stream, which starts and stops the watcher for you:

``` elixir
"/tmp"
|> Flier.Inotify.stream([:close_write])
|> Enum.each(fn event -> IO.puts("#{event.name}: #{inspect(event.masks)}") end)
```

The `:moved_from` and `:moved_to` events of a rename carry the same
`:cookie`, so the two halves can be paired up.

Errors are POSIX error atoms, as with `File`:

``` elixir
{:error, :enoent} = Flier.Inotify.start_watcher("/does/not/exist", :all)
```

## Listing a directory

``` elixir
"/tmp"
|> Flier.Entries.stream()
|> Enum.each(fn entry -> IO.puts("#{entry.name} is a #{entry.type}") end)
```

Recursively, with an optional depth limit and symlink following:

``` elixir
root = "/home/user/projects"

root
|> Flier.Entries.stream(recursive: true, max_depth: 3)
|> Stream.filter(&(&1.type == :file))
|> Enum.map(&Path.join([root, &1.path, &1.name]))
```

If the root directory cannot be read, enumerating the stream raises a
`File.Error`. Unreadable subdirectories are skipped, unless
`on_error: :raise` is given.

## Documentation

Full documentation is at <https://hexdocs.pm/flier>.
