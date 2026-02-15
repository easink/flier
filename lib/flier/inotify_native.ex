defmodule Flier.Inotify.Native do
  @moduledoc false

  use Rustler,
    otp_app: :flier,
    crate: :flier_inotify

  # When loading a NIF module, dummy clauses for all NIF function are required.
  # NIF dummies usually just error out when called when the NIF is not loaded, as that should never normally happen.
  # def my_native_function(_arg1, _arg2), do: :erlang.nif_error(:nif_not_loaded)
  # def add(_arg1, _arg2), do: :erlang.nif_error(:nif_not_loaded)

  def start_watcher(_path, _mask, _pid), do: :erlang.nif_error(:nif_not_loaded)
  def stop_watcher(_ref), do: :erlang.nif_error(:nif_not_loaded)

  # def on_down(_resource, _pid, _reason), do: :erlang.nif_error(:nif_not_loaded)

  def opendir(_path, _mask, _pid), do: :erlang.nif_error(:nif_not_loaded)
  def readdir(_ref), do: :erlang.nif_error(:nif_not_loaded)
  def closedir(_ref), do: :erlang.nif_error(:nif_not_loaded)
end
