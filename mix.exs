defmodule Tinderbox.MixProject do
  use Mix.Project

  def project do
    [
      app: :tinderbox,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :eex]]

  defp deps do
    [
      # `optional: true` is the ecosystem convention for igniter-powered packages
      # (see ash's own mix.exs): the consumer's `mix igniter.new`/`igniter.install`
      # run supplies igniter for `:dev`/`:test`, and declaring it as a hard dep
      # instead makes mix fail with "Dependencies have diverged: the :only option
      # for dependency igniter".
      {:igniter, "~> 0.8", optional: true}
    ]
  end
end
