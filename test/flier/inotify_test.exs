defmodule Flier.InotifyTest do
  use ExUnit.Case, async: false

  @moduletag :inotify

  setup do
    # Create temp directory for testing
    tmp_dir = Path.join(System.tmp_dir!(), "flier_inotify_test_#{:rand.uniform(1_000_000)}")
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

    test "returns error for non-existent path" do
      non_existent = "/tmp/flier_test_does_not_exist_#{:rand.uniform(1_000_000)}"
      assert {:error, _reason} = Flier.Inotify.start_watcher(non_existent, :all)
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
  end
end
