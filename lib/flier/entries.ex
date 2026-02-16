defmodule Flier.Entries do
  @moduledoc false

  @spec stream(path :: String.t()) :: Enumerable.t()
  def stream(path) do
    Stream.resource(
      fn ->
        {:ok, ref} = Flier.Entries.Native.opendir(path)
        ref
      end,
      fn ref ->
        case Flier.Entries.Native.readdir(ref) do
          {:ok, entry} -> {[entry], ref}
          {:error, _reason} -> {:halt, ref}
        end
      end,
      fn ref -> Flier.Entries.Native.closedir(ref) end
    )
  end
end
