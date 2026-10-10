defmodule Flier.MixProject do
  use Mix.Project

  @version "0.5.0"
  @url "https://github.com/easink/flier"

  def project do
    [
      app: :flier,
      name: "Flier",
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      source_url: @url,
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler, "~> 0.38", optional: true},
      {:rustler_precompiled, "~> 0.10"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.0", only: :dev}
    ]
  end

  defp docs do
    [
      main: "Flier",
      extras: ["README.md"],
      groups_for_modules: [
        "File watching": [Flier.Inotify, Flier.Inotify.Watcher, Flier.Inotify.Event],
        "Directory listing": [Flier.Entries, Flier.Entries.Entry]
      ]
    ]
  end

  defp description() do
    "Library for inotify and stream file listing."
  end

  defp package() do
    [
      name: "flier",
      # These are the default files included in the package
      # The root Cargo.toml (workspace) and Cargo.lock are needed to build
      # the NIFs from source.
      files:
        ~w(lib native Cargo.toml Cargo.lock .formatter.exs mix.exs README* LICENSE* checksum-*.exs),
      licenses: ["MIT"],
      links: %{"GitHub" => @url}
    ]
  end

  # Mix runs a task only once per invocation, so listing the download task
  # twice in an alias would skip the second crate; rerun it explicitly.
  defp gen_checksum(_args) do
    for module <- ~w(Flier.Entries.Native Flier.Inotify.Native) do
      Mix.Task.rerun("rustler_precompiled.download", [module, "--all", "--print"])
    end
  end

  defp aliases do
    [
      "format.all": ["format", "rust.fmt"],
      "rust.lint": [
        "cmd cargo clippy --manifest-path=native/flier_inotify/Cargo.toml -- -Dwarnings",
        "cmd cargo clippy --manifest-path=native/flier_entries/Cargo.toml -- -Dwarnings"
      ],
      "rust.fmt": [
        "cmd cargo fmt --manifest-path=native/flier_inotify/Cargo.toml --all",
        "cmd cargo fmt --manifest-path=native/flier_entries/Cargo.toml --all"
      ],
      "gen.checksum": &gen_checksum/1,
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, ip: {127, 0, 0, 1}, port: 4001) end)'"
    ]
  end
end
