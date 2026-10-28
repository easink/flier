defmodule Flier.InotifyPropertyTest do
  # Not async: the leak checks count the inotify instances and reader threads
  # of the whole VM.
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :inotify

  alias Flier.Inotify.Event

  @events [
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
    :delete_self,
    :move_self
  ]
  @report_only [:ignored, :isdir, :q_overflow, :unmount]

  # Events whose occurrence follows exactly from the operations below.
  @namespace_events [:create, :delete, :moved_from, :moved_to]

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "flier_inotify_prop_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  property "start_watcher/2 accepts exactly the masks naming a subscribable event",
           %{tmp_dir: tmp_dir} do
    atoms = @events ++ @report_only ++ [:close, :closed, :bogus]

    check all(mask <- list_of(member_of(atoms), max_length: 5)) do
      known? = Enum.all?(mask, &(&1 in @events or &1 in @report_only or &1 == :close))
      subscribable? = Enum.any?(mask, &(&1 in @events or &1 == :close))

      if known? and subscribable? do
        assert {:ok, watcher} = Flier.Inotify.start_watcher(tmp_dir, mask)
        Flier.Inotify.stop_watcher(watcher)
      else
        assert_raise ArgumentError, fn -> Flier.Inotify.start_watcher(tmp_dir, mask) end
      end
    end
  end

  property "watchers sharing a directory each get exactly the events of their mask, in order",
           %{tmp_dir: tmp_dir} do
    check all(
            ops <- list_of(operation(), max_length: 25),
            masks <- list_of(sub_mask(), max_length: 4)
          ) do
      in_dir(tmp_dir, fn dir ->
        {:ok, %{ref: all_ref} = all} = Flier.Inotify.start_watcher(dir, @namespace_events)
        watchers = Enum.map(masks, &{&1, start!(dir, &1)})

        expected = apply_ops(dir, ops)
        File.write!(Path.join(dir, "sentinel"), "")
        events = receive_until_sentinel(all_ref)

        assert Enum.map(events, &{&1.name, &1.masks}) == expected
        assert_cookies(events)

        for {mask, %{ref: ref}} <- watchers do
          # Report-only flags in a mask subscribe to nothing.
          wanted =
            Enum.filter(expected, fn {_name, masks} ->
              Enum.any?(masks, &(&1 in mask and &1 in @events))
            end)

          assert Enum.map(received(ref), &{&1.name, &1.masks}) -- [{"sentinel", [:create]}] ==
                   wanted
        end

        Enum.each([all | Enum.map(watchers, &elem(&1, 1))], &stop_and_flush/1)
      end)
    end
  end

  property "a watcher gets no events for changes made before it started", %{tmp_dir: tmp_dir} do
    check all(steps <- list_of(member_of([:write, :join]), max_length: 40)) do
      in_dir(tmp_dir, fn dir ->
        # The first watcher keeps the kernel watch shared by the later ones.
        first = start!(dir, [:create])

        # Each joined watcher with the names written after it started.
        joined =
          steps
          |> Enum.with_index()
          |> Enum.reduce([], fn
            {:join, _}, joined ->
              [{start!(dir, [:create]), []} | joined]

            {:write, i}, joined ->
              name = "f#{i}"
              File.write!(Path.join(dir, name), "")
              Enum.map(joined, fn {watcher, names} -> {watcher, [name | names]} end)
          end)

        File.write!(Path.join(dir, "sentinel"), "")

        for {%{ref: ref}, names} <- joined do
          assert Enum.map(receive_until_sentinel(ref), & &1.name) == Enum.reverse(names)
        end

        Enum.each([first | Enum.map(joined, &elem(&1, 0))], &stop_and_flush/1)
      end)
    end
  end

  property "watchers on a removed directory each get :ignored last, then nothing",
           %{tmp_dir: tmp_dir} do
    check all(
            masks <- list_of(sub_mask(), min_length: 1, max_length: 5),
            stopped <- list_of(boolean(), length: length(masks))
          ) do
      in_dir(tmp_dir, fn dir ->
        watchers = Enum.map(masks, &start!(dir, &1))
        {stop, keep} = watchers |> Enum.zip(stopped) |> Enum.split_with(&elem(&1, 1))
        Enum.each(stop, fn {watcher, _} -> stop_and_flush(watcher) end)

        File.rm_rf!(dir)

        for {%{ref: ref}, _} <- keep do
          assert_receive {:inotify_event, ^ref, %Event{masks: [:ignored]}}, 2000
          refute_receive {:inotify_event, ^ref, _}, 20
        end

        for {%{ref: ref}, _} <- stop, do: refute_received({:inotify_event, ^ref, _})
        Enum.each(keep, fn {watcher, _} -> stop_and_flush(watcher) end)
      end)
    end

    assert_released()
  end

  property "concurrent watchers get no events once stopped and release everything",
           %{tmp_dir: tmp_dir} do
    check all(
            scripts <- list_of(script(), min_length: 2, max_length: 8),
            max_runs: 50
          ) do
      dirs = for i <- 1..3, do: Path.join(tmp_dir, "d#{i}")
      Enum.each(dirs, &File.mkdir_p!/1)

      scripts
      |> Enum.map(fn script -> Task.async(fn -> run_script(script, dirs) end) end)
      |> Task.await_many(30_000)

      assert_released()

      # The hub starts again after shutting down.
      Enum.each(dirs, &File.mkdir_p!/1)
      dir = hd(dirs)
      %{ref: ref} = watcher = start!(dir, [:create])
      File.write!(Path.join(dir, "fresh"), "")
      assert_receive {:inotify_event, ^ref, %Event{name: "fresh"}}, 2000
      stop_and_flush(watcher)
      Enum.each(dirs, &File.rm_rf!/1)
    end
  end

  ## Generators

  defp file_name, do: member_of(~w(a b c d))

  defp operation do
    one_of([
      tuple({constant(:write), file_name()}),
      tuple({constant(:mkdir), file_name()}),
      tuple({constant(:delete), file_name()}),
      tuple({constant(:rename), file_name(), file_name()})
    ])
  end

  # A non-empty subset of the namespace events, maybe with report-only flags.
  defp sub_mask do
    gen all(
          events <- subset(@namespace_events) |> filter(&(&1 != [])),
          flags <- subset(@report_only)
        ) do
      events ++ flags
    end
  end

  defp subset(list) do
    list
    |> Enum.map(&tuple({constant(&1), boolean()}))
    |> fixed_list()
    |> map(fn picks -> for {item, true} <- picks, do: item end)
  end

  # The steps one process takes against a shared set of directories.
  defp script do
    frequency([
      {4, tuple({constant(:start), integer(0..2)})},
      {3, tuple({constant(:stop), integer(0..9)})},
      {3, tuple({constant(:write), integer(0..2)})},
      {1, tuple({constant(:recreate), integer(0..2)})}
    ])
    |> list_of(max_length: 30)
    # Whether the process ends by stopping its watchers or just exiting.
    |> then(&tuple({&1, boolean()}))
  end

  ## Model

  # Apply the operations in `dir`, skipping those that would fail, and return
  # the {name, masks} of the namespace events they cause, in order.
  defp apply_ops(dir, ops) do
    {events, _entries} =
      Enum.reduce(ops, {[], %{}}, fn op, {events, entries} ->
        {new, entries} = apply_op(dir, op, entries)
        {events ++ new, entries}
      end)

    events
  end

  defp apply_op(dir, {:write, name}, entries) do
    case entries[name] do
      nil ->
        File.write!(Path.join(dir, name), "")
        {[{name, [:create]}], Map.put(entries, name, :file)}

      :file ->
        File.write!(Path.join(dir, name), "more")
        {[], entries}

      :dir ->
        {[], entries}
    end
  end

  defp apply_op(dir, {:mkdir, name}, entries) do
    if entries[name] do
      {[], entries}
    else
      File.mkdir!(Path.join(dir, name))
      {[{name, [:create, :isdir]}], Map.put(entries, name, :dir)}
    end
  end

  defp apply_op(dir, {:delete, name}, entries) do
    case entries[name] do
      nil ->
        {[], entries}

      :file ->
        File.rm!(Path.join(dir, name))
        {[{name, [:delete]}], Map.delete(entries, name)}

      :dir ->
        File.rmdir!(Path.join(dir, name))
        {[{name, [:delete, :isdir]}], Map.delete(entries, name)}
    end
  end

  defp apply_op(dir, {:rename, from, to}, entries) do
    case {entries[from], entries[to]} do
      {kind, target}
      when from != to and ((kind == :file and target != :dir) or (kind == :dir and target == nil)) ->
        File.rename!(Path.join(dir, from), Path.join(dir, to))
        flags = if kind == :dir, do: [:isdir], else: []
        events = [{from, [:moved_from | flags]}, {to, [:moved_to | flags]}]
        {events, entries |> Map.delete(from) |> Map.put(to, kind)}

      _ ->
        {[], entries}
    end
  end

  # Both halves of a rename share a cookie no other rename uses; all other
  # events have none.
  defp assert_cookies(events) do
    {moves, others} = Enum.split_with(events, &(:moved_from in &1.masks or :moved_to in &1.masks))
    assert Enum.all?(others, &(&1.cookie == 0))

    pairs = Enum.chunk_every(moves, 2)
    assert Enum.all?(pairs, fn [from, to] -> from.cookie != 0 and from.cookie == to.cookie end)
    assert length(Enum.uniq_by(pairs, &hd(&1).cookie)) == length(pairs)
  end

  ## Concurrent scripts

  defp run_script({steps, stop_at_end?}, dirs) do
    {live, stopped} =
      Enum.reduce(steps, {[], []}, fn
        {:start, d}, {live, stopped} ->
          # Fails while another process recreates the directory.
          case Flier.Inotify.start_watcher(Enum.at(dirs, d), [:create]) do
            {:ok, watcher} -> {[watcher | live], stopped}
            {:error, :enoent} -> {live, stopped}
          end

        {:stop, _i}, {[], stopped} ->
          {[], stopped}

        {:stop, i}, {live, stopped} ->
          {watcher, live} = List.pop_at(live, rem(i, length(live)))
          stop_and_flush(watcher)
          {live, [watcher | stopped]}

        {:write, d}, acc ->
          # Fails while another process recreates the directory.
          File.write(Path.join(Enum.at(dirs, d), "w#{System.unique_integer([:positive])}"), "")
          acc

        {:recreate, d}, acc ->
          # Races with other processes writing to or recreating it.
          File.rm_rf(Enum.at(dirs, d))
          File.mkdir_p(Enum.at(dirs, d))
          acc
      end)

    for %{ref: ref} <- stopped do
      refute_received {:inotify_event, ^ref, _}, "an event arrived after stop_watcher/1"
    end

    if stop_at_end?, do: Enum.each(live, &stop_and_flush/1)
  end

  ## Helpers

  defp in_dir(tmp_dir, fun) do
    dir = Path.join(tmp_dir, "w#{System.unique_integer([:positive])}")
    File.mkdir!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  defp start!(dir, mask) do
    {:ok, watcher} = Flier.Inotify.start_watcher(dir, mask)
    watcher
  end

  defp stop_and_flush(%{ref: ref} = watcher) do
    :stopped = Flier.Inotify.stop_watcher(watcher)
    received(ref)
  end

  defp receive_until_sentinel(ref, acc \\ []) do
    receive do
      {:inotify_event, ^ref, %Event{name: "sentinel"}} -> Enum.reverse(acc)
      {:inotify_event, ^ref, event} -> receive_until_sentinel(ref, [event | acc])
    after
      2000 -> flunk("no sentinel event, got: #{inspect(Enum.reverse(acc))}")
    end
  end

  # The events of `ref` already in the mailbox.
  defp received(ref, acc \\ []) do
    receive do
      {:inotify_event, ^ref, event} -> received(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Once every watcher is gone, the inotify instance and its reader thread
  # are released.
  defp assert_released do
    :erlang.garbage_collect()

    eventually(fn -> inotify_fds() == 0 and reader_threads() == 0 end) ||
      flunk("#{inotify_fds()} inotify fds and #{reader_threads()} reader threads left")
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end

  defp inotify_fds do
    Enum.count(File.ls!("/proc/self/fd"), fn fd ->
      File.read_link("/proc/self/fd/" <> fd) == {:ok, "anon_inode:inotify"}
    end)
  end

  defp reader_threads do
    Enum.count(File.ls!("/proc/self/task"), fn task ->
      match?({:ok, "flier_inotify\n"}, File.read("/proc/self/task/#{task}/comm"))
    end)
  end
end
