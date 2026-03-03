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

      assert file_entry.type == :file
      assert dir_entry.type == :directory
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
      assert Map.has_key?(entry, :type)
      assert Map.has_key?(entry, :path)
    end

    test "flat stream entries have path: \".\"", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "content")

      [entry] = Flier.Entries.stream(tmp_dir) |> Enum.to_list()

      assert entry.path == "."
    end
  end

  describe "Flier.Entries.stream/2 (recursive)" do
    test "visits all nested entries", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "root.txt"), "content")
      File.mkdir!(Path.join(tmp_dir, "subdir"))
      File.write!(Path.join(tmp_dir, "subdir/nested.txt"), "content")

      entries = Flier.Entries.stream(tmp_dir, recursive: true) |> Enum.to_list()
      names = Enum.map(entries, & &1.name) |> Enum.sort()

      assert names == ["nested.txt", "root.txt", "subdir"]
    end

    test "root-level entries have path: \".\"", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "root.txt"), "content")
      File.mkdir!(Path.join(tmp_dir, "subdir"))

      entries = Flier.Entries.stream(tmp_dir, recursive: true) |> Enum.to_list()

      root_entries = Enum.filter(entries, &(&1.name in ["root.txt", "subdir"]))
      assert Enum.all?(root_entries, &(&1.path == "."))
    end

    test "nested entries have correct :path", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "a/b"))
      File.write!(Path.join(tmp_dir, "a/b/deep.txt"), "content")

      entries = Flier.Entries.stream(tmp_dir, recursive: true) |> Enum.to_list()

      deep = Enum.find(entries, &(&1.name == "deep.txt"))
      assert deep.path == "a/b"
    end

    test "path + name yields correct full path", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "sub"))
      File.write!(Path.join(tmp_dir, "sub/file.txt"), "content")

      entries = Flier.Entries.stream(tmp_dir, recursive: true) |> Enum.to_list()

      file = Enum.find(entries, &(&1.name == "file.txt"))
      full = Path.expand(Path.join([tmp_dir, file.path, file.name]))
      assert full == Path.join(tmp_dir, "sub/file.txt")
    end

    test "max_depth: 0 returns only root-level entries", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "root.txt"), "content")
      File.mkdir!(Path.join(tmp_dir, "subdir"))
      File.write!(Path.join(tmp_dir, "subdir/nested.txt"), "content")

      entries = Flier.Entries.stream(tmp_dir, recursive: true, max_depth: 0) |> Enum.to_list()
      names = Enum.map(entries, & &1.name) |> Enum.sort()

      assert names == ["root.txt", "subdir"]
    end

    test "max_depth: 1 includes one subdir level", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "a/b"))
      File.write!(Path.join(tmp_dir, "root.txt"), "content")
      File.write!(Path.join(tmp_dir, "a/level1.txt"), "content")
      File.write!(Path.join(tmp_dir, "a/b/level2.txt"), "content")

      entries = Flier.Entries.stream(tmp_dir, recursive: true, max_depth: 1) |> Enum.to_list()
      names = Enum.map(entries, & &1.name) |> Enum.sort()

      assert "root.txt" in names
      assert "level1.txt" in names
      refute "level2.txt" in names
    end

    test "does not follow symlinks by default", %{tmp_dir: tmp_dir} do
      # Put the target file in an external dir — only reachable via the symlink
      external = Path.join(System.tmp_dir!(), "flier_ext_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(external)
      File.write!(Path.join(external, "external.txt"), "content")
      File.ln_s!(external, Path.join(tmp_dir, "link_dir"))

      on_exit(fn -> File.rm_rf!(external) end)

      entries = Flier.Entries.stream(tmp_dir, recursive: true) |> Enum.to_list()
      names = Enum.map(entries, & &1.name)

      # The symlink entry itself is yielded
      assert "link_dir" in names
      # But its contents are not visited
      refute "external.txt" in names
    end

    test "follows symlinks when follow_symlinks: true", %{tmp_dir: tmp_dir} do
      # Same setup: target only reachable via symlink
      external = Path.join(System.tmp_dir!(), "flier_ext_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(external)
      File.write!(Path.join(external, "external.txt"), "content")
      File.ln_s!(external, Path.join(tmp_dir, "link_dir"))

      on_exit(fn -> File.rm_rf!(external) end)

      entries =
        Flier.Entries.stream(tmp_dir, recursive: true, follow_symlinks: true) |> Enum.to_list()

      names = Enum.map(entries, & &1.name)
      assert "external.txt" in names
    end

    test "on_error: :skip silently skips unreadable subdirs", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "root.txt"), "content")
      File.mkdir!(Path.join(tmp_dir, "subdir"))
      File.write!(Path.join(tmp_dir, "subdir/nested.txt"), "content")
      File.mkdir!(Path.join(tmp_dir, "no_access"))
      File.chmod!(Path.join(tmp_dir, "no_access"), 0o000)

      entries =
        Flier.Entries.stream(tmp_dir, recursive: true, on_error: :skip) |> Enum.to_list()

      names = Enum.map(entries, & &1.name)

      assert "root.txt" in names
      assert "nested.txt" in names
      assert "no_access" in names

      File.chmod!(Path.join(tmp_dir, "no_access"), 0o755)
    end

    test "on_error: :raise raises on unreadable subdir", %{tmp_dir: tmp_dir} do
      File.mkdir!(Path.join(tmp_dir, "no_access"))
      File.chmod!(Path.join(tmp_dir, "no_access"), 0o000)

      assert_raise RuntimeError, ~r/cannot open directory/, fn ->
        Flier.Entries.stream(tmp_dir, recursive: true, on_error: :raise) |> Enum.to_list()
      end

      File.chmod!(Path.join(tmp_dir, "no_access"), 0o755)
    end

    test "empty directory returns empty list", %{tmp_dir: tmp_dir} do
      assert [] == Flier.Entries.stream(tmp_dir, recursive: true) |> Enum.to_list()
    end

    test "stream can be halted early and cleans up", %{tmp_dir: tmp_dir} do
      for i <- 1..10, do: File.write!(Path.join(tmp_dir, "file#{i}.txt"), "content")

      entries = Flier.Entries.stream(tmp_dir, recursive: true) |> Enum.take(3)
      assert length(entries) == 3
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
