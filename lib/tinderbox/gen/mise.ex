defmodule Tinderbox.Gen.Mise do
  @moduledoc """
  Generates `.mise.toml` for a stack: the pinned toolchain, the local environment
  and the dev-loop tasks.

  * `[tools]` — Elixir and Erlang, pinned to the toolchain running the generator
    (see `Tinderbox.Toolchain`), plus CMake for the Kafka worker, whose `brod`
    dependency builds a NIF from source.
  * `[env]` — the same values as `.env.example`; both come from `Tinderbox.Env`.
  * `[tasks.*]` — `up`, `down`, `setup`, `dev`, `test`, `check`, and `health` for
    the worker. They are inline tables rather than `.mise/tasks/*` files because a
    file task has to be executable, which the files an igniter writes are not,
    and mise does not list a non-executable file task until it is first run.

  `.mise.local.toml` is added to `.gitignore`: it is where machine-specific
  overrides go, and mise layers it over `.mise.toml`.

  Called by `mix tinderbox.gen.mise`.
  """

  alias Tinderbox.Broker
  alias Tinderbox.Env
  alias Tinderbox.Gen
  alias Tinderbox.Toolchain

  @spec apply(Igniter.t(), Keyword.t()) :: Igniter.t()
  def apply(igniter, opts) do
    app = Igniter.Project.Application.app_name(igniter)
    stack = Keyword.get(opts, :stack, "api")
    broker = Broker.parse!(Keyword.get(opts, :broker) || "sqs")
    compose? = Keyword.get(opts, :compose, true)
    worker? = stack == "worker"

    # `opts[:vm]` stands in for the running VM (a `t:Tinderbox.Toolchain.vm/0`): it is
    # how tests generate "as if" on another Elixir/OTP. The Mix task never sets it.
    vm = Keyword.get_lazy(opts, :vm, &Toolchain.detect/0)
    {source, pins} = Toolchain.pins(vm)

    env =
      Env.sections(
        app: app,
        module: Igniter.Project.Module.module_name_prefix(igniter),
        stack: stack,
        broker: broker,
        db?: Keyword.get(opts, :db, true)
      )

    serve = if worker?, do: "mix run --no-halt", else: "mix phx.server"

    assigns = [
      app: app,
      elixir: pins.elixir,
      erlang: pins.erlang,
      cmake: Toolchain.cmake(),
      cmake?: worker? and broker == :kafka,
      compose?: compose?,
      worker?: worker?,
      serve: serve,
      env: Env.toml(env),
      dev_summary: dev_summary(compose?, serve),
      dev_description: dev_description(compose?, worker?)
    ]

    content =
      "mise.toml.eex"
      |> Gen.render_template(assigns)
      |> String.trim_trailing()
      |> Kernel.<>("\n")

    igniter
    |> Igniter.create_new_file(".mise.toml", content)
    |> Gen.ignore([".mise.local.toml"])
    |> add_fallback_notice(source, vm, pins)
  end

  defp add_fallback_notice(igniter, :running, _vm, _pins), do: igniter

  defp add_fallback_notice(igniter, :fallback, vm, pins) do
    Igniter.add_notice(
      igniter,
      "Elixir #{vm.elixir} is a dev or pre-release build, which mise has no version for, " <>
        "so .mise.toml pins Elixir #{pins.elixir} and Erlang #{pins.erlang}, the toolchain " <>
        "this package was verified with. Edit [tools] to match the `elixir:` requirement " <>
        "in mix.exs."
    )
  end

  defp dev_summary(true, serve), do: "up + setup + #{serve}"
  defp dev_summary(false, serve), do: "setup + #{serve}"

  defp dev_description(compose?, worker?) do
    start =
      if compose?,
        do: "Start the services, set up the database and run",
        else: "Set up the database and run"

    what =
      if worker?, do: "the worker (health on :4001)", else: "the API (http://localhost:4000/api)"

    "#{start} #{what}"
  end
end
