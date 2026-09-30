defmodule Tinderbox.Gen.Mise do
  @moduledoc """
  Generates `.mise.toml` for a stack: the pinned toolchain, the local environment
  and the dev-loop tasks.

  * `[tools]` — Elixir and Erlang (plus CMake for the Kafka worker, whose `brod`
    dependency builds a NIF from source).
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

  # Elixir and Erlang mirror this package's own `.mise.toml` (a test keeps the two
  # in sync), which follows the pins ankusa uses. CMake is what ankusa pins for
  # the same brod NIF.
  @versions %{elixir: "1.20.4-otp-29", erlang: "29.1", cmake: "4.4.3"}

  @doc "The tool versions written to `[tools]`."
  @spec versions() :: %{elixir: String.t(), erlang: String.t(), cmake: String.t()}
  def versions, do: @versions

  @spec apply(Igniter.t(), Keyword.t()) :: Igniter.t()
  def apply(igniter, opts) do
    app = Igniter.Project.Application.app_name(igniter)
    stack = Keyword.get(opts, :stack, "api")
    broker = Broker.parse!(Keyword.get(opts, :broker) || "sqs")
    compose? = Keyword.get(opts, :compose, true)
    worker? = stack == "worker"

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
      elixir: @versions.elixir,
      erlang: @versions.erlang,
      cmake: @versions.cmake,
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
