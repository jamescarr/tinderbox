defmodule Tinderbox.MixProject do
  use Mix.Project

  def project do
    [
      app: :tinderbox,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # The SaaS generator calls the Ash/Spark igniter helpers. A project without
      # Ash (`--stack ui`) still compiles this package when a generator is
      # re-run, and would otherwise warn about every one of them.
      elixirc_options: [
        no_warn_undefined: [
          Ash.Igniter,
          Ash.Resource.Igniter,
          Ash.Domain.Igniter,
          Spark.Igniter,
          AshAuthentication.Igniter
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application, do: [extra_applications: [:logger, :eex]]

  defp deps do
    [
      # `optional: true` is the ecosystem convention for igniter-powered packages
      # (see ash's own mix.exs): the consumer's `mix igniter.new`/`igniter.install`
      # run supplies igniter for `:dev`/`:test`, and declaring it as a hard dep
      # instead makes mix fail with "Dependencies have diverged: the :only option
      # for dependency igniter".
      {:igniter, "~> 0.8", optional: true},
      # The SaaS generator calls into these (`Ash.Resource.Igniter`,
      # `Ash.Domain.Igniter`, `Spark.Igniter`, `AshAuthentication.Igniter`) to edit
      # the resources their installers wrote. Optional for the same reason as
      # igniter: the generated project supplies them. They are here so this
      # package's own tests can run the generator against a fixture project.
      {:ash, "~> 3.34", optional: true},
      {:ash_authentication, "~> 4.15", optional: true}
    ]
  end
end
