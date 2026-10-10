defmodule Mix.Tasks.Tinderbox.Install do
  @shortdoc "Installs one of the stacks (api | worker | saas) into the current project"

  @moduledoc """
  Entry point igniter runs for `mix igniter.install tinderbox` — and
  therefore the task `mix igniter.new … --install tinderbox@path:…` invokes.

  ```sh
  # API stack
  mix igniter.new my_api --with phx.new \\
    --with-args="--no-html --no-assets --no-live --no-dashboard --no-mailer --no-gettext" \\
    --install tinderbox@path:/Users/jamescarr/projects/upmarkethq/tinderbox \\
    --stack api

  # Worker stack
  mix igniter.new my_worker --sup \\
    --install tinderbox@path:/Users/jamescarr/projects/upmarkethq/tinderbox \\
    --stack worker --broker sqs

  # SaaS stack
  mix igniter.new my_app --with phx.new \\
    --install tinderbox@path:/Users/jamescarr/projects/upmarkethq/tinderbox \\
    --stack saas
  ```

  * `--stack api|worker|saas` (required) selects the generator
    (`tinderbox.gen.api` / `tinderbox.gen.worker` / `tinderbox.gen.saas`).
  * `--broker sqs|pubsub|rabbitmq|kafka|nats` is passed to the worker generator.
    The SaaS stack always runs its event bus on NATS JetStream, whatever
    `--broker` says.
  * `--no-compose` skips `docker-compose.yml` / `.env.example`.
  * `--no-mise` skips `.mise.toml` (toolchain pins, environment, dev-loop tasks).
  * `--no-demo` skips the API stack's demo domain and resource (ignored by saas).

  Because only one stack is generated per project, the dependency list and the
  composed tasks are computed from `--stack` in `info/2`: an API project does not
  pull in the Broadway clients, a worker project does not pull in
  AshJsonApi/AshPhoenix, and neither pulls in the SaaS stack's authentication,
  billing and admin packages.
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(argv, _source) do
    stack = flag_value(argv, "stack")

    %Igniter.Mix.Task.Info{
      group: :tinderbox,
      example: "mix igniter.install tinderbox --stack saas",
      schema: [stack: :string, broker: :string, compose: :boolean, mise: :boolean, demo: :boolean],
      defaults: [broker: "sqs", compose: true, mise: true, demo: true],
      required: [:stack],
      # Keep the template out of the generated app's runtime dependencies.
      only: [:dev, :test],
      dep_opts: [runtime: false],
      composes: composes(stack),
      # `mix igniter.new` forwards its own flags (e.g. `--new-with`, `--yes-to-deps`).
      extra_args?: true
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options
    flags = igniter.args.argv_flags

    igniter =
      case opts[:stack] do
        "api" ->
          Igniter.compose_task(igniter, "tinderbox.gen.api", flags)

        "worker" ->
          Igniter.compose_task(igniter, "tinderbox.gen.worker", flags)

        "saas" ->
          Igniter.compose_task(igniter, "tinderbox.gen.saas", flags)

        other ->
          Mix.raise(~s|Unknown --stack #{inspect(other)}. Must be "api", "worker" or "saas".|)
      end

    broker = broker(opts)

    igniter =
      if opts[:compose] do
        Igniter.compose_task(igniter, "tinderbox.gen.compose", [
          "--stack",
          opts[:stack],
          "--broker",
          broker
        ])
      else
        igniter
      end

    if opts[:mise] do
      Igniter.compose_task(
        igniter,
        "tinderbox.gen.mise",
        ["--stack", opts[:stack], "--broker", broker] ++
          if(opts[:compose], do: [], else: ["--no-compose"])
      )
    else
      igniter
    end
  end

  # The SaaS stack's event bus is NATS JetStream, so compose and mise get the
  # nats broker whatever `--broker` was given (its default is `sqs`).
  defp broker(opts) do
    if opts[:stack] == "saas", do: "nats", else: opts[:broker] || "sqs"
  end

  # `info/2` runs before igniter parses the options, and igniter merges the
  # `composes:` schemas (and their `installs:`) before any task runs — so the
  # stack has to be read from argv to keep the two stacks' dependencies apart.
  defp composes("api"), do: ["tinderbox.gen.api", "tinderbox.gen.compose", "tinderbox.gen.mise"]

  defp composes("worker"),
    do: ["tinderbox.gen.worker", "tinderbox.gen.compose", "tinderbox.gen.mise"]

  defp composes("saas"),
    do: ["tinderbox.gen.saas", "tinderbox.gen.compose", "tinderbox.gen.mise"]

  defp composes(_missing_or_unknown), do: []

  defp flag_value(argv, name) do
    argv
    # `--tinderbox.stack api` is the namespaced spelling igniter accepts.
    |> Enum.map(&String.replace_prefix(&1, "--tinderbox.", "--"))
    |> do_flag_value(name)
  end

  defp do_flag_value(["--" <> rest | tail], name) do
    cond do
      rest == name -> List.first(tail)
      String.starts_with?(rest, name <> "=") -> String.replace_prefix(rest, name <> "=", "")
      true -> do_flag_value(tail, name)
    end
  end

  defp do_flag_value([_arg | tail], name), do: do_flag_value(tail, name)
  defp do_flag_value([], _name), do: nil
end
