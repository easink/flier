defmodule Flier.Inotify.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :flier,
    crate: :flier_inotify,
    base_url: "https://github.com/easink/flier/releases/download/v#{version}",
    force_build: System.get_env("FLIER_BUILD") in ["1", "true"],
    version: version,
    targets: ~w(
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
      arm-unknown-linux-gnueabihf
      riscv64gc-unknown-linux-gnu
    ),
    nif_versions: ["2.16", "2.17"]

  def start_watcher(_path, _mask, _pid), do: :erlang.nif_error(:nif_not_loaded)
  def stop_watcher(_ref), do: :erlang.nif_error(:nif_not_loaded)
end
