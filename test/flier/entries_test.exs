defmodule Flier.EntriesTest do
  use ExUnit.Case, async: false

  @moduletag :entries

  setup do
    # Create temp directory for testing
    tmp_dir = Path.join(System.tmp_dir!(), "flier_entries_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "Flier.Entries.Native.opendir/1" do
    test "returns {:ok, ref} for valid directory", %{tmp_dir: tmp_dir} do
      assert {:ok, ref} = Flier.Entries.Native.opendir(tmp_dir)
      assert is_reference(ref)
      Flier.Entries.Native.closedir(ref)
    end

    test "returns {:error, :not_found} for non-existent path" do
      non_existent = "/tmp/flier_test_does_not_exist_#{:rand.uniform(1_000_000)}"
      assert {:error, :not_found} = Flier.Entries.Native.opendir(non_existent)
    end

    test "returns error for file path", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test_file.txt")
      File.write!(file_path, "content")
      assert {:error, _reason} = Flier.Entries.Native.opendir(file_path)
    end
  end

  describe "Flier.Entries.Native.readdir/1" do
    test "reads entries from directory", %{tmp_dir: tmp_dir} do
      # Create some files and directories
      File.write!(Path.join(tmp_dir, "file1.txt"), "content")
      File.write!(Path.join(tmp_dir, "file2.txt"), "content")
      File.mkdir!(Path.join(tmp_dir, "subdir"))

      {:ok, ref} = Flier.Entries.Native.opendir(tmp_dir)

      # Read all entries
      entries = read_all_entries(ref)
      Flier.Entries.Native.closedir(ref)

      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert names == ["file1.txt", "file2.txt", "subdir"]
    end

    test "returns correct file types", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "regular_file.txt"), "content")
      File.mkdir!(Path.join(tmp_dir, "directory"))

      {:ok, ref} = Flier.Entries.Native.opendir(tmp_dir)
      entries = read_all_entries(ref)
      Flier.Entries.Native.closedir(ref)

      file_entry = Enum.find(entries, &(&1.name == "regular_file.txt"))
      dir_entry = Enum.find(entries, &(&1.name == "directory"))

      assert file_entry.type_ == :file
      assert dir_entry.type_ == :directory
    end

    test "returns {:error, :end_of_directory} when exhausted", %{tmp_dir: tmp_dir} do
      # Empty directory
      {:ok, ref} = Flier.Entries.Native.opendir(tmp_dir)
      assert {:error, :end_of_directory} = Flier.Entries.Native.readdir(ref)
      Flier.Entries.Native.closedir(ref)
    end

    test "returns {:error, :already_closed} after close", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Entries.Native.opendir(tmp_dir)
      Flier.Entries.Native.closedir(ref)
      assert {:error, :already_closed} = Flier.Entries.Native.readdir(ref)
    end
  end

  describe "Flier.Entries.Native.closedir/1" do
    test "returns :closed", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Entries.Native.opendir(tmp_dir)
      assert :closed = Flier.Entries.Native.closedir(ref)
    end

    test "can be called multiple times", %{tmp_dir: tmp_dir} do
      {:ok, ref} = Flier.Entries.Native.opendir(tmp_dir)
      assert :closed = Flier.Entries.Native.closedir(ref)
      assert :closed = Flier.Entries.Native.closedir(ref)
    end
  end

  describe "Flier.Entries.stream/1" do
    test "streams all entries in directory", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "content")
      File.write!(Path.join(tmp_dir, "b.txt"), "content")
      File.write!(Path.join(tmp_dir, "c.txt"), "content")

      entries = Flier.Entries.stream(tmp_dir) |> Enum.to_list()

      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert names == ["a.txt", "b.txt", "c.txt"]
    end

    test "returns empty list for empty directory", %{tmp_dir: tmp_dir} do
      entries = Flier.Entries.stream(tmp_dir) |> Enum.to_list()
      assert entries == []
    end

    test "can be used with Enum.take", %{tmp_dir: tmp_dir} do
      for i <- 1..10, do: File.write!(Path.join(tmp_dir, "file#{i}.txt"), "content")

      entries = Flier.Entries.stream(tmp_dir) |> Enum.take(3)
      assert length(entries) == 3
    end

    test "properly cleans up resources", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "content")

      # Take only 1 entry and let the stream be garbage collected
      _entries = Flier.Entries.stream(tmp_dir) |> Enum.take(1)

      # If resources are properly cleaned up, we should be able to open again
      {:ok, ref} = Flier.Entries.Native.opendir(tmp_dir)
      Flier.Entries.Native.closedir(ref)
    end

    test "handles directories with many files", %{tmp_dir: tmp_dir} do
      for i <- 1..100 do
        File.write!(
          Path.join(tmp_dir, "file_#{String.pad_leading("#{i}", 3, "0")}.txt"),
          "content"
        )
      end

      entries = Flier.Entries.stream(tmp_dir) |> Enum.to_list()
      assert length(entries) == 100
    end

    test "handles nested directories", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir!(subdir)
      File.write!(Path.join(subdir, "nested.txt"), "content")
      File.write!(Path.join(tmp_dir, "root.txt"), "content")

      # Stream only reads the top level
      entries = Flier.Entries.stream(tmp_dir) |> Enum.to_list()
      names = Enum.map(entries, & &1.name) |> Enum.sort()

      assert names == ["root.txt", "subdir"]
    end
  end

  describe "Flier.Entries.Entry struct" do
    test "has expected fields", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "content")

      [entry] = Flier.Entries.stream(tmp_dir) |> Enum.to_list()

      assert %Flier.Entries.Entry{} = entry
      assert Map.has_key?(entry, :name)
      assert Map.has_key?(entry, :type_)
    end
  end

  # Helper to read all entries from a directory reference
  defp read_all_entries(ref, acc \\ []) do
    case Flier.Entries.Native.readdir(ref) do
      {:ok, entry} -> read_all_entries(ref, [entry | acc])
      {:error, :end_of_directory} -> Enum.reverse(acc)
    end
  end
end
