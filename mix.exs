defmodule Flier.MixProject do
  use Mix.Project

  @url "https://github.com/easink/flier.git"

  def project do
    [
      app: :flier,
      name: "Flier",
      version: "0.1.1",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      source_url: @url
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
      {:rustler, "~> 0.37.1", optional: true, runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      # {:rustler_precompiled, "~> 0.7"},
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.0", only: :dev}
    ]
  end

  defp description() do
    "Library for inotify and stream file listing."
  end

  defp package() do
    [
      name: "flier",
      # These are the default files included in the package
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*),
      licenses: ["MIT"],
      links: %{"GitHub" => @url}
    ]
  end

  defp aliases do
    [
      # setup: ["deps.get", "compile"],
      # "deps.vendorize": ["cmd cp -rv ../autumn/native/autumn native/comrak_nif/vendor"],
      # "gen.checksum": "rustler_precompiled.download MDEx.Native --all --print",
      "format.all": ["format", "rust.fmt"],
      "rust.lint": [
        "cmd cargo clippy --manifest-path=native/flier_inotify/Cargo.toml -- -Dwarnings"
      ],
      "rust.fmt": [
        "cmd cargo fmt --manifest-path=native/flier_inotify/Cargo.toml --all",
        "cmd cargo fmt --manifest-path=native/flier_entries/Cargo.toml --all"
      ],
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, ip: {127, 0, 0, 1}, port: 4000) end)'"
    ]
  end
end
