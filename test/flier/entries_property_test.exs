defmodule Flier.EntriesPropertyTest do
  # Not async: the leak checks count the file descriptors of the whole VM.
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :entries

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "flier_entries_prop_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  # A tree is a map of name => node, where a node is :file, :fifo,
  # {:dir, tree} or, once links are added, {:link, target}. A link target is
  # {:dir, path}, {:file, path} or :broken, where path is the list of names
  # from the root.

  property "a recursive walk yields every entry of the tree once, with its type and path",
           %{tmp_dir: tmp_dir} do
    check all(
            tree <- tree(3),
            max_depth <- max_depth()
          ) do
      in_root(tmp_dir, tree, fn root ->
        assert sorted(Flier.Entries.stream(root, recursive: true, max_depth: max_depth)) ==
                 Enum.sort(model(tree, max_depth: max_depth))
      end)
    end
  end

  property "a flat listing yields the root's entries only", %{tmp_dir: tmp_dir} do
    check all(tree <- tree(2)) do
      in_root(tmp_dir, tree, fn root ->
        assert sorted(Flier.Entries.stream(root)) == Enum.sort(model(tree, max_depth: 0))
      end)
    end
  end

  property "symlinked directories are followed once per branch and cycles terminate",
           %{tmp_dir: tmp_dir} do
    check all(
            {tree, follow, max_depth} <- linked_tree(),
            max_runs: 200
          ) do
      in_root(tmp_dir, tree, fn root ->
        entries =
          Flier.Entries.stream(root,
            recursive: true,
            follow_symlinks: follow,
            max_depth: max_depth
          )

        assert sorted(entries) ==
                 Enum.sort(model(tree, max_depth: max_depth, follow_symlinks: follow))
      end)
    end
  end

  property "a directory's contents come after the entry naming it", %{tmp_dir: tmp_dir} do
    check all({tree, follow, max_depth} <- linked_tree()) do
      in_root(tmp_dir, tree, fn root ->
        root
        |> Flier.Entries.stream(recursive: true, follow_symlinks: follow, max_depth: max_depth)
        |> Enum.reduce(MapSet.new(["."]), fn entry, seen ->
          assert entry.path in seen,
                 "#{inspect(entry)} came before the entry for its directory"

          MapSet.put(seen, join(entry.path, entry.name))
        end)
      end)
    end
  end

  property "directories spanning several native batches are read completely",
           %{tmp_dir: tmp_dir} do
    check all(
            root_files <- integer(250..520),
            sub_files <- integer(0..300),
            max_runs: 15
          ) do
      in_root(tmp_dir, %{}, fn root ->
        for i <- 1..root_files//1, do: File.write!(Path.join(root, "f#{i}"), "")
        File.mkdir!(Path.join(root, "sub"))
        for i <- 1..sub_files//1, do: File.write!(Path.join([root, "sub", "g#{i}"]), "")

        entries = Enum.to_list(Flier.Entries.stream(root, recursive: true))

        assert length(entries) == root_files + 1 + sub_files
        assert length(Enum.uniq(entries)) == length(entries)
      end)
    end
  end

  property "concurrent walks of one tree all yield the same entries", %{tmp_dir: tmp_dir} do
    check all(tree <- tree(3), max_runs: 50) do
      in_root(tmp_dir, tree, fn root ->
        expected = Enum.sort(model(tree, max_depth: :infinity))

        1..8
        |> Enum.map(fn _ ->
          Task.async(fn -> sorted(Flier.Entries.stream(root, recursive: true)) end)
        end)
        |> Task.await_many(10_000)
        |> Enum.each(&assert(&1 == expected))
      end)
    end
  end

  property "concurrent readdir calls on one handle split the directory between them",
           %{tmp_dir: tmp_dir} do
    check all(
            count <- integer(0..600),
            batch_sizes <- list_of(integer(1..64), length: 4),
            max_runs: 30
          ) do
      in_root(tmp_dir, %{}, fn root ->
        names = for i <- 1..count//1, do: "f#{i}"
        Enum.each(names, &File.write!(Path.join(root, &1), ""))
        {:ok, ref} = Flier.Entries.Native.opendir(root)

        read =
          batch_sizes
          |> Enum.map(fn max -> Task.async(fn -> read_all(ref, max) end) end)
          |> Task.await_many(10_000)
          |> List.flatten()

        assert Enum.sort(read) == Enum.sort(names)
        Flier.Entries.Native.closedir(ref)
      end)
    end
  end

  property "a walk never fails while subdirectories are removed under it with on_error: :skip",
           %{tmp_dir: tmp_dir} do
    check all(tree <- tree(3), max_runs: 50) do
      in_root(tmp_dir, tree, fn root ->
        expected = MapSet.new(model(tree, max_depth: :infinity))

        remover =
          Task.async(fn ->
            for {name, {:dir, _}} <- tree, do: File.rm_rf!(Path.join(root, name))
          end)

        walked = sorted(Flier.Entries.stream(root, recursive: true, on_error: :skip))
        Task.await(remover)

        assert MapSet.subset?(MapSet.new(walked), expected)
      end)
    end
  end

  property "halting a walk early closes every directory it opened", %{tmp_dir: tmp_dir} do
    check all(
            tree <- tree(4),
            take <- integer(0..30),
            max_runs: 50
          ) do
      in_root(tmp_dir, tree, fn root ->
        before = open_dirs(root)
        Enum.take(Flier.Entries.stream(root, recursive: true), take)
        assert open_dirs(root) == before
      end)
    end
  end

  property "a walk that raises closes every directory it opened", %{tmp_dir: tmp_dir} do
    check all(
            tree <- nested_dirs(),
            locked <- member_of(Map.keys(tree)),
            max_runs: 50
          ) do
      in_root(tmp_dir, tree, fn root ->
        # Directories may already be open when the walk reaches this one.
        locked = Path.join([root, locked, "d"])
        File.chmod!(locked, 0o000)

        try do
          before = open_dirs(root)

          assert_raise File.Error, fn ->
            Enum.to_list(Flier.Entries.stream(root, recursive: true, on_error: :raise))
          end

          assert open_dirs(root) == before
        after
          File.chmod!(locked, 0o755)
        end
      end)
    end
  end

  property "stream/2 accepts exactly the documented options", %{tmp_dir: tmp_dir} do
    check all(opts <- options()) do
      if Enum.all?(opts, &valid_option?/1) do
        assert is_list(Enum.to_list(Flier.Entries.stream(tmp_dir, opts)))
      else
        assert_raise ArgumentError, fn -> Flier.Entries.stream(tmp_dir, opts) end
      end
    end
  end

  ## Generators

  # Names may hold any byte but "/" and NUL, and need not be UTF-8.
  defp name do
    raw =
      integer(1..255)
      |> filter(&(&1 != ?/))
      |> list_of(min_length: 1, max_length: 6)
      |> map(&:erlang.list_to_binary/1)

    [string(:alphanumeric, min_length: 1, max_length: 8), raw]
    |> one_of()
    |> filter(&(&1 not in [".", ".."]))
  end

  defp tree(depth) do
    {name(), tree_node(depth)}
    |> tuple()
    |> uniq_list_of(uniq_fun: &elem(&1, 0), max_length: 5)
    |> map(&Map.new/1)
  end

  defp tree_node(0), do: member_of([:file, :fifo, {:dir, %{}}])

  defp tree_node(depth) do
    frequency([
      {3, constant(:file)},
      {1, constant(:fifo)},
      {3, map(tree(depth - 1), &{:dir, &1})}
    ])
  end

  defp max_depth, do: one_of([constant(:infinity), integer(0..4)])

  # A tree with symlinks to its directories (the root included), its files,
  # and to nowhere.
  defp linked_tree do
    gen all(
          tree <- tree(2),
          dirs = paths(tree, :dir),
          files = paths(tree, :file),
          links <-
            list_of(tuple({member_of(dirs), name(), link_target(dirs, files)}), max_length: 4),
          follow <- boolean(),
          max_depth <- one_of([constant(:infinity), integer(0..6)])
        ) do
      tree =
        Enum.reduce(links, tree, fn {at, name, target}, tree ->
          add_link(tree, at, name, target)
        end)

      {tree, follow, max_depth}
    end
  end

  defp link_target(dirs, []), do: one_of([map(member_of(dirs), &{:dir, &1}), constant(:broken)])

  defp link_target(dirs, files) do
    one_of([
      map(member_of(dirs), &{:dir, &1}),
      map(member_of(files), &{:file, &1}),
      constant(:broken)
    ])
  end

  # Several directories each holding a directory "d" with a file.
  defp nested_dirs do
    string(:alphanumeric, min_length: 1, max_length: 4)
    |> uniq_list_of(min_length: 2, max_length: 5)
    |> map(&Map.new(&1, fn name -> {name, {:dir, %{"d" => {:dir, %{"f" => :file}}}}} end))
  end

  defp options do
    value =
      one_of([
        boolean(),
        integer(-2..5),
        member_of([:infinity, :skip, :raise, :other, nil, "true"])
      ])

    [:recursive, :max_depth, :follow_symlinks, :on_error, :unknown]
    |> Map.new(&{&1, value})
    |> optional_map()
    |> map(&Map.to_list/1)
  end

  ## Model

  defp valid_option?({:recursive, value}), do: is_boolean(value)
  defp valid_option?({:follow_symlinks, value}), do: is_boolean(value)

  defp valid_option?({:max_depth, value}),
    do: value == :infinity or (is_integer(value) and value >= 0)

  defp valid_option?({:on_error, value}), do: value in [:skip, :raise]
  defp valid_option?(_option), do: false

  # The {path, name, type} triples a walk of `tree` should yield.
  defp model(tree, opts) do
    walk(tree, [], ".", 0, [[]], Map.new(opts))
  end

  defp walk(tree, at, rel, depth, ancestors, opts) do
    tree
    |> children(at)
    |> Enum.flat_map(fn {name, node} ->
      below =
        with true <- descend?(depth, opts),
             {:ok, dir} <- walked_dir(node, at ++ [name], ancestors, opts) do
          walk(tree, dir, join(rel, name), depth + 1, [dir | ancestors], opts)
        else
          _ -> []
        end

      [{rel, name, type(node)} | below]
    end)
  end

  # The directory a walk descends into through `node`, if any.
  defp walked_dir({:dir, _}, path, _ancestors, _opts), do: {:ok, path}

  defp walked_dir({:link, {:dir, target}}, _path, ancestors, %{follow_symlinks: true}),
    do: if(target in ancestors, do: :error, else: {:ok, target})

  defp walked_dir(_node, _path, _ancestors, _opts), do: :error

  defp descend?(_depth, %{max_depth: :infinity}), do: true
  defp descend?(depth, %{max_depth: max_depth}), do: depth < max_depth

  defp type(:file), do: :file
  defp type(:fifo), do: :other
  defp type({:dir, _}), do: :directory
  defp type({:link, _}), do: :symlink

  defp children(tree, []), do: tree
  defp children(tree, [name | rest]), do: tree |> Map.fetch!(name) |> elem(1) |> children(rest)

  # The paths of the directories (the root included) or files of `tree`.
  defp paths(tree, kind, at \\ []) do
    own = if kind == :dir, do: [at], else: []

    own ++
      Enum.flat_map(tree, fn
        {name, {:dir, sub}} -> paths(sub, kind, at ++ [name])
        {name, :file} when kind == :file -> [at ++ [name]]
        _ -> []
      end)
  end

  # Adds a link unless its name is taken in that directory.
  defp add_link(tree, [], name, target), do: Map.put_new(tree, name, {:link, target})

  defp add_link(tree, [dir | rest], name, target) do
    Map.update!(tree, dir, fn {:dir, sub} -> {:dir, add_link(sub, rest, name, target)} end)
  end

  defp join(".", name), do: name
  defp join(rel, name), do: rel <> "/" <> name

  ## Helpers

  defp in_root(tmp_dir, tree, fun) do
    root = Path.join(tmp_dir, "root_#{System.unique_integer([:positive])}")
    File.mkdir!(root)

    try do
      build!(root, root, tree)
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end

  defp build!(root, dir, tree) do
    for {name, node} <- tree do
      path = Path.join(dir, name)

      case node do
        :file ->
          File.write!(path, "")

        :fifo ->
          # mkfifo takes the name as an argument, so create it under a plain
          # name and rename it.
          tmp = Path.join(System.tmp_dir!(), "flier_fifo_#{System.unique_integer([:positive])}")
          {_, 0} = System.cmd("mkfifo", [tmp])
          File.rename!(tmp, path)

        {:dir, sub} ->
          File.mkdir!(path)
          build!(root, path, sub)

        {:link, {_kind, target}} ->
          File.ln_s!(Path.join([root | target]), path)

        {:link, :broken} ->
          File.ln_s!(Path.join(root, "does not exist"), path)
      end
    end
  end

  defp sorted(entries), do: entries |> Enum.map(&{&1.path, &1.name, &1.type}) |> Enum.sort()

  defp read_all(ref, max, acc \\ []) do
    case Flier.Entries.Native.readdir(ref, max) do
      {:ok, entries} -> read_all(ref, max, [Enum.map(entries, & &1.name) | acc])
      {:error, :end_of_directory} -> acc
    end
  end

  # Directories below `root` the VM holds open.
  defp open_dirs(root) do
    for fd <- File.ls!("/proc/self/fd"),
        {:ok, target} <- [File.read_link("/proc/self/fd/" <> fd)],
        String.starts_with?(target, root),
        do: target
  end
end
