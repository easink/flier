defmodule Flier.InotifyTest do
  use ExUnit.Case, async: true

  @moduletag :inotify

  setup do
    # Create temp directory for testing. Use a unique integer rather than
    # :rand.uniform/1 so that async test processes can never collide.
    tmp_dir =
      Path.join(System.tmp_dir!(), "flier_inotify_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "start_watcher/3" do
    test "returns {:ok, ref} when watching a valid directory", %{tmp_dir: tmp_dir} do
      assert {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, :all)
      assert is_reference(ref)
      Flier.Inotify.stop_watcher(ref)
    end

    test "returns {:ok, ref} with specific event mask", %{tmp_dir: tmp_dir} do
      assert {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create, :delete])
      assert is_reference(ref)
      Flier.Inotify.stop_watcher(ref)
    end

    test "returns {:error, :failed_to_add_watcher} for non-existent path" do
      non_existent =
        "/tmp/flier_test_does_not_exist_#{System.unique_integer([:positive])}"

      assert {:error, :failed_to_add_watcher} =
               Flier.Inotify.start_watcher(non_existent, :all)
    end
  end

  describe "stop_watcher/1" do
    test "returns :stopped after stopping a watcher", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, :all)
      assert :stopped = Flier.Inotify.stop_watcher(ref)
    end

    test "can start and stop watcher multiple times", %{tmp_dir: tmp_dir} do
      for _ <- 1..3 do
        {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, :all)
        assert :stopped = Flier.Inotify.stop_watcher(ref)
      end
    end
  end

  describe "file creation events" do
    test "detects file creation with :create mask", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create])

      # Create a file
      test_file = Path.join(tmp_dir, "test_create.txt")
      File.write!(test_file, "hello")

      assert_receive {:inotify_event, filename, masks}, 1000
      assert filename == "test_create.txt"
      assert :create in masks

      Flier.Inotify.stop_watcher(ref)
    end

    test "detects file creation with :all mask", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, :all)

      test_file = Path.join(tmp_dir, "test_create_all.txt")
      File.write!(test_file, "hello")

      assert_receive {:inotify_event, "test_create_all.txt", masks}, 1000
      assert :create in masks

      Flier.Inotify.stop_watcher(ref)
    end
  end

  describe "file modification events" do
    test "detects file modification", %{tmp_dir: tmp_dir} do
      # Create file first
      test_file = Path.join(tmp_dir, "test_modify.txt")
      File.write!(test_file, "initial content")

      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:modify])

      # Modify the file
      File.write!(test_file, "modified content")

      assert_receive {:inotify_event, "test_modify.txt", masks}, 1000
      assert :modify in masks

      Flier.Inotify.stop_watcher(ref)
    end
  end

  describe "file deletion events" do
    test "detects file deletion", %{tmp_dir: tmp_dir} do
      # Create file first
      test_file = Path.join(tmp_dir, "test_delete.txt")
      File.write!(test_file, "to be deleted")

      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:delete])

      # Delete the file
      File.rm!(test_file)

      assert_receive {:inotify_event, "test_delete.txt", masks}, 1000
      assert :delete in masks

      Flier.Inotify.stop_watcher(ref)
    end
  end

  describe "file open events" do
    test "detects file open", %{tmp_dir: tmp_dir} do
      # Create file first
      test_file = Path.join(tmp_dir, "test_open.txt")
      File.write!(test_file, "content")

      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:open])

      # Open the file
      {:ok, fd} = File.open(test_file, [:read])
      File.close(fd)

      assert_receive {:inotify_event, "test_open.txt", masks}, 1000
      assert :open in masks

      Flier.Inotify.stop_watcher(ref)
    end
  end

  describe "file close events" do
    test "detects close_write event", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:close_write])

      test_file = Path.join(tmp_dir, "test_close_write.txt")
      # File.write! opens, writes, and closes - should trigger close_write
      File.write!(test_file, "content")

      assert_receive {:inotify_event, "test_close_write.txt", masks}, 1000
      assert :close_write in masks

      Flier.Inotify.stop_watcher(ref)
    end

    test "detects close_nowrite event", %{tmp_dir: tmp_dir} do
      # Create file first
      test_file = Path.join(tmp_dir, "test_close_nowrite.txt")
      File.write!(test_file, "content")

      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:close_nowrite])

      # Open file in read-only mode and close
      {:ok, fd} = File.open(test_file, [:read])
      File.close(fd)

      assert_receive {:inotify_event, "test_close_nowrite.txt", masks}, 1000
      assert :close_nowrite in masks

      Flier.Inotify.stop_watcher(ref)
    end
  end

  describe "file access events" do
    test "detects file access", %{tmp_dir: tmp_dir} do
      # Create file first
      test_file = Path.join(tmp_dir, "test_access.txt")
      File.write!(test_file, "content to read")

      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:access])

      # Read the file (triggers access)
      File.read!(test_file)

      assert_receive {:inotify_event, "test_access.txt", masks}, 1000
      assert :access in masks

      Flier.Inotify.stop_watcher(ref)
    end
  end

  describe "file move events" do
    test "detects moved_from when file is renamed", %{tmp_dir: tmp_dir} do
      # Create file first
      test_file = Path.join(tmp_dir, "test_move_from.txt")
      File.write!(test_file, "content")

      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:moved_from])

      # Rename the file
      new_file = Path.join(tmp_dir, "test_moved.txt")
      File.rename!(test_file, new_file)

      assert_receive {:inotify_event, "test_move_from.txt", masks}, 1000
      assert :moved_from in masks

      Flier.Inotify.stop_watcher(ref)
    end

    test "detects moved_to when file is renamed", %{tmp_dir: tmp_dir} do
      # Create file first
      test_file = Path.join(tmp_dir, "test_move_source.txt")
      File.write!(test_file, "content")

      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:moved_to])

      # Rename the file
      new_file = Path.join(tmp_dir, "test_move_dest.txt")
      File.rename!(test_file, new_file)

      assert_receive {:inotify_event, "test_move_dest.txt", masks}, 1000
      assert :moved_to in masks

      Flier.Inotify.stop_watcher(ref)
    end
  end

  describe "directory events" do
    test "detects directory creation with :isdir mask", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create, :isdir])

      # Create a subdirectory
      sub_dir = Path.join(tmp_dir, "test_subdir")
      File.mkdir!(sub_dir)

      assert_receive {:inotify_event, "test_subdir", masks}, 1000
      assert :create in masks
      assert :isdir in masks

      Flier.Inotify.stop_watcher(ref)
    end
  end

  describe "attribute change events" do
    test "detects attribute changes", %{tmp_dir: tmp_dir} do
      # Create file first
      test_file = Path.join(tmp_dir, "test_attrib.txt")
      File.write!(test_file, "content")

      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:attrib])

      # Change file permissions (triggers attrib)
      File.chmod!(test_file, 0o644)

      assert_receive {:inotify_event, "test_attrib.txt", masks}, 1000
      assert :attrib in masks

      Flier.Inotify.stop_watcher(ref)
    end
  end

  describe "multiple events" do
    test "receives multiple events for different operations", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create, :modify, :delete])

      # Create file
      test_file = Path.join(tmp_dir, "test_multi.txt")
      File.write!(test_file, "initial")

      # Should receive create event
      assert_receive {:inotify_event, "test_multi.txt", create_masks}, 1000
      assert :create in create_masks

      # Drain any additional events from the initial write (e.g., modify, close_write)
      drain_events("test_multi.txt")

      # Modify file
      File.write!(test_file, "modified")

      # Should receive modify event
      assert_receive {:inotify_event, "test_multi.txt", modify_masks}, 1000
      assert :modify in modify_masks

      # Drain any additional events from the modify operation
      drain_events("test_multi.txt")

      # Delete file
      File.rm!(test_file)

      # Should receive delete event
      assert_receive {:inotify_event, "test_multi.txt", delete_masks}, 1000
      assert :delete in delete_masks

      Flier.Inotify.stop_watcher(ref)
    end
  end

  # Helper to drain pending events for a specific file
  defp drain_events(filename) do
    receive do
      {:inotify_event, ^filename, _} -> drain_events(filename)
    after
      50 -> :ok
    end
  end

  # Helper to create a uniquely-named tmp directory under System.tmp_dir!/0.
  defp make_tmp(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  # Collect all inotify events arriving within `timeout_ms` of silence.
  defp collect_events(timeout_ms), do: collect_events_loop([], timeout_ms)

  defp collect_events_loop(acc, timeout_ms) do
    receive do
      {:inotify_event, name, masks} ->
        collect_events_loop([{name, masks} | acc], timeout_ms)
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end

  # Wait until an event with the :ignored mask arrives (and discard any
  # unrelated events that may precede it).
  defp assert_eventually_ignored(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually_ignored(deadline)
  end

  defp do_assert_eventually_ignored(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:inotify_event, _name, masks} ->
        if :ignored in masks do
          true
        else
          do_assert_eventually_ignored(deadline)
        end
    after
      remaining -> flunk("did not receive an :ignored event within timeout")
    end
  end

  describe "stream/2" do
    test "creates a stream that yields events", %{tmp_dir: tmp_dir} do
      # Start a task to create files after a delay
      test_file = Path.join(tmp_dir, "stream_test.txt")

      Task.start(fn ->
        Process.sleep(100)
        File.write!(test_file, "hello")
      end)

      # Take the first event from the stream
      [{filename, masks}] =
        tmp_dir
        |> Flier.Inotify.stream([:create])
        |> Enum.take(1)

      assert filename == "stream_test.txt"
      assert :create in masks
    end
  end

  describe "custom pid" do
    test "sends events to specified pid", %{tmp_dir: tmp_dir} do
      parent = self()

      # Spawn a process to receive events
      receiver =
        spawn(fn ->
          receive do
            {:inotify_event, filename, masks} ->
              send(parent, {:received, filename, masks})
          end
        end)

      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create], receiver)

      # Create a file
      test_file = Path.join(tmp_dir, "custom_pid_test.txt")
      File.write!(test_file, "hello")

      # The parent should receive the forwarded message
      assert_receive {:received, "custom_pid_test.txt", masks}, 1000
      assert :create in masks

      Flier.Inotify.stop_watcher(ref)
    end
  end

  describe "edge cases" do
    test "handles rapid file operations", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create])

      # Create multiple files rapidly
      for i <- 1..5 do
        test_file = Path.join(tmp_dir, "rapid_#{i}.txt")
        File.write!(test_file, "content #{i}")
      end

      # Should receive events for all files
      received =
        for _ <- 1..5 do
          assert_receive {:inotify_event, filename, _masks}, 1000
          filename
        end

      assert length(received) == 5

      assert Enum.sort(received) ==
               ~w(rapid_1.txt rapid_2.txt rapid_3.txt rapid_4.txt rapid_5.txt)

      Flier.Inotify.stop_watcher(ref)
    end

    test "does not receive events after stop_watcher", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create])
      :stopped = Flier.Inotify.stop_watcher(ref)

      # Create a file after stopping
      test_file = Path.join(tmp_dir, "after_stop.txt")
      File.write!(test_file, "should not trigger event")

      # Should not receive any event
      refute_receive {:inotify_event, _, _}, 200
    end

    test "returns error for empty mask list", %{tmp_dir: tmp_dir} do
      # Empty mask list is not allowed by the NIF
      assert {:error, :failed_to_add_watcher} = Flier.Inotify.start_watcher(tmp_dir, [])
    end

    test "two watchers on different dirs deliver independent events", %{tmp_dir: tmp1} do
      tmp2 = make_tmp("flier_inotify_two")
      on_exit(fn -> File.rm_rf!(tmp2) end)

      {:ok, r1} = Flier.Inotify.start_watcher(tmp1, [:create])
      {:ok, r2} = Flier.Inotify.start_watcher(tmp2, [:create])

      File.write!(Path.join(tmp1, "a.txt"), "x")
      File.write!(Path.join(tmp2, "b.txt"), "x")

      assert_receive {:inotify_event, name1, _}, 1000
      assert_receive {:inotify_event, name2, _}, 1000

      assert Enum.sort([name1, name2]) == ["a.txt", "b.txt"]

      Flier.Inotify.stop_watcher(r1)
      Flier.Inotify.stop_watcher(r2)
    end

    test "watcher tolerates recipient pid dying without hanging stop_watcher",
         %{tmp_dir: tmp_dir} do
      recipient = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create], recipient)

      Process.exit(recipient, :kill)
      # Give the Rust thread a chance to detect send failure on the next event.
      Process.sleep(50)
      File.write!(Path.join(tmp_dir, "ghost.txt"), "x")
      Process.sleep(150)

      # stop_watcher must not block forever even though the recipient is gone.
      task = Task.async(fn -> Flier.Inotify.stop_watcher(ref) end)
      assert :stopped = Task.await(task, 500)
    end

    test "delivers :ignored event when watched directory is removed",
         %{tmp_dir: tmp_dir} do
      # The kernel always delivers :ignored when the watch is removed,
      # regardless of the requested mask.
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create])
      File.rm_rf!(tmp_dir)

      assert_eventually_ignored(1000)
      Flier.Inotify.stop_watcher(ref)
    end

    test "watcher with multiple events delivers each type", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create, :modify])

      f = Path.join(tmp_dir, "multi.txt")
      File.write!(f, "a")
      Process.sleep(20)
      File.write!(f, "b")

      events = collect_events(2000)
      assert Enum.any?(events, fn {_, m} -> :create in m end),
             "expected at least one :create event in #{inspect(events)}"

      assert Enum.any?(events, fn {_, m} -> :modify in m end),
             "expected at least one :modify event in #{inspect(events)}"

      Flier.Inotify.stop_watcher(ref)
    end

    test ":all mask observes create, modify, delete in one session", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, :all)

      f = Path.join(tmp_dir, "all.txt")
      File.write!(f, "x")
      Process.sleep(20)
      File.write!(f, "y")
      Process.sleep(20)
      File.rm!(f)

      events = collect_events(2000)
      observed = events |> Enum.flat_map(fn {_, m} -> m end) |> MapSet.new()

      for expected <- [:create, :modify, :delete] do
        assert expected in observed,
               "expected #{inspect(expected)} in #{inspect(observed)}"
      end

      Flier.Inotify.stop_watcher(ref)
    end

    test "stop_watcher/1 is idempotent", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create])
      assert :stopped = Flier.Inotify.stop_watcher(ref)
      assert :stopped = Flier.Inotify.stop_watcher(ref)
    end

    test "stream/2 stops the underlying watcher when the enumerator process exits",
         %{tmp_dir: tmp_dir} do
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          send(parent, :started)
          # Block forever waiting for an event we will never send.
          tmp_dir |> Flier.Inotify.stream([:create]) |> Enum.take(1)
        end)

      assert_receive :started, 500
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000

      # If the underlying NIF thread had leaked, it would still be polling and
      # could send {:inotify_event, ...} to the now-dead pid (harmless) — but
      # critically, the test process must never see those events.
      File.write!(Path.join(tmp_dir, "after_exit.txt"), "x")
      refute_receive {:inotify_event, _, _}, 200
    end

    test "delivers UTF-8 filenames intact", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create])
      name = "αβγ-日本語.txt"
      File.write!(Path.join(tmp_dir, name), "x")

      assert_receive {:inotify_event, ^name, _}, 1000

      Flier.Inotify.stop_watcher(ref)
    end

    test "preserves raw bytes for non-UTF-8 filenames", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create])

      # Three bytes that are not valid UTF-8.
      bad = <<0xFF, 0xFE, 0xFD>>
      path = :erlang.iolist_to_binary([tmp_dir, "/", bad])
      :ok = :file.write_file(path, "x")

      assert_receive {:inotify_event, name, _}, 1000
      # Option B: the raw bytes are preserved as an Erlang binary.
      assert name == bad
      refute name == ""

      Flier.Inotify.stop_watcher(ref)
    end

    test "handles long filenames near NAME_MAX", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create])

      name = String.duplicate("x", 200) <> ".txt"
      File.write!(Path.join(tmp_dir, name), "x")

      assert_receive {:inotify_event, ^name, _}, 1000

      Flier.Inotify.stop_watcher(ref)
    end

    @tag :slow
    test "delivers 500 rapid create events", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Inotify.start_watcher(tmp_dir, [:create])

      for i <- 1..500, do: File.write!(Path.join(tmp_dir, "f#{i}.txt"), "x")

      received =
        for _ <- 1..500 do
          assert_receive {:inotify_event, name, _}, 5000
          name
        end

      assert length(Enum.uniq(received)) == 500

      Flier.Inotify.stop_watcher(ref)
    end

    test "watcher is cleaned up when the resource is garbage-collected", %{tmp_dir: tmp_dir} do
      # Start a watcher in a child function so the ResourceArc has no
      # remaining Elixir-side references after the call returns. The Rust
      # `Drop` impl on WatcherResource must then stop the polling thread.
      start_and_drop = fn ->
        {:ok, _ref} = Flier.Inotify.start_watcher(tmp_dir, [:create])
        :ok
      end

      :ok = start_and_drop.()

      # Force a couple of GC passes to ensure the resource is reclaimed.
      :erlang.garbage_collect(self())
      Process.sleep(50)
      :erlang.garbage_collect(self())

      # If the thread is still running, creating a file would still produce
      # an event (the thread sends to the original caller pid, which is this
      # test process). After GC + Drop, no event should arrive.
      test_file = Path.join(tmp_dir, "after_gc.txt")
      File.write!(test_file, "should not trigger event")

      refute_receive {:inotify_event, _, _}, 300
    end
  end
end
