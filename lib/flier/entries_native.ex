defmodule Flier.Entries.Native do
  @moduledoc false

  use Rustler,
    otp_app: :flier,
    crate: :flier_entries

  def opendir(_path), do: :erlang.nif_error(:nif_not_loaded)
  def readdir(_ref), do: :erlang.nif_error(:nif_not_loaded)
  def closedir(_ref), do: :erlang.nif_error(:nif_not_loaded)
end
