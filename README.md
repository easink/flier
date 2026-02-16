# Flier

Add some file functions in Elixir by adding some NIFs using Rustler.

- inotify
- file listing stream

## Examples (inotify)

~~~elixir
{:ok, ref} = Flier.Inotify.start_watcher("/tmp", [:create])
receive do
    {:inotify_event, file, masks} -> IO.puts("File '#{file}' triggered by #{inspect mask})
end
:stopped = Flier.Inotify.stop_watcher(ref)
~~~~

~~~elixir
"/tmp"
|> Flier.Inotify.stream([:close_write])
|> Enum.each(fn {file, mask} -> IO.puts("File '#{file}' triggered by #{inspect mask})
~~~~

## Examples (entries)

~~~elixir
"/tmp"
|> Flier.Entries.stream()
|> Enum.each(fn entry -> IO.puts("Entry '#{entry.name}' is a '#{entry.type}'")
~~~~


## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be
installed by adding `flier` to your list of dependencies in `mix.exs`:

``` elixir
def deps do
  [
    {:flier, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with
[ExDoc](https://github.com/elixir-lang/ex_doc) and published on
[HexDocs](https://hexdocs.pm). Once published, the docs can be found at
<https://hexdocs.pm/flier>.
