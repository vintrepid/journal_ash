defmodule JournalAsh.MixProject do
  use Mix.Project

  @version "0.1.0-alpha.1"
  @source_url "https://github.com/vintrepid/journal_ash"

  def project do
    [
      app: :journal_ash,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A bounded activity journal and Logger integration for Ash applications",
      hex: [ignore_advisories: ["EEF-CVE-2026-32686"]],
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {JournalAsh.Application, []}
    ]
  end

  defp deps do
    [
      ash_dependency(),
      # Decimal 3.0.0 contains the upstream fix for CVE-2026-32686. Hex's
      # advisory feed currently marks every version affected, so the project
      # acknowledgement above is paired with this enforced safe range.
      {:decimal, ">= 3.0.0 and < 4.0.0"},
      {:telemetry, "~> 1.0"},
      # Ash exposes generators at runtime and already requires StreamData. We
      # declare our direct use explicitly instead of applying a conflicting
      # test-only restriction to the same dependency.
      {:stream_data, "~> 1.0"},
      {:sourceror, "~> 1.12", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp ash_dependency do
    path = System.get_env("JOURNAL_ASH_ASH_PATH")
    git = System.get_env("JOURNAL_ASH_ASH_GIT")
    reference = nonempty_env("JOURNAL_ASH_ASH_REF", "main")

    cond do
      is_binary(path) and path != "" ->
        {:ash, path: Path.expand(path), override: true}

      is_binary(git) and git != "" ->
        {:ash, git: git, ref: reference, override: true}

      true ->
        {:ash, nonempty_env("JOURNAL_ASH_ASH_VERSION", "~> 3.33")}
    end
  end

  defp nonempty_env(name, default) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _missing_or_empty -> default
    end
  end

  defp package do
    [
      maintainers: ["Vince"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md SECURITY.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "SECURITY.md"]
    ]
  end
end
