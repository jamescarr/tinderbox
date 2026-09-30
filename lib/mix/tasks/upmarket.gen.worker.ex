defmodule Mix.Tasks.Upmarket.Gen.Worker do
  @shortdoc "Generates the worker stack (Broadway + AshPostgres idempotency store)"

  @moduledoc """
  Generates a headless worker: a Broadway pipeline that consumes from one
  messaging endpoint, records each message id in an Ash/AshPostgres idempotency
  store, and publishes the transformed message to a second endpoint of the same
  broker (`--broker sqs | pubsub | rabbitmq | kafka`).

  The Ash packages are fetched and their installers are run by igniter, so this
  task must be run through `mix igniter.install`/`mix igniter.new`:

  ```sh
  mix igniter.new my_worker --sup \\
    --install upmarket_stack@path:/Users/jamescarr/projects/upmarkethq/upmarket_stack \\
    --stack worker --broker sqs
  ```
  """

  use Igniter.Mix.Task

  alias UpmarketStack.Broker

  @impl Igniter.Mix.Task
  def info(argv, _source) do
    broker = Broker.parse!(broker_flag(argv) || "sqs")

    %Igniter.Mix.Task.Info{
      group: :upmarket,
      example: "mix upmarket.gen.worker --broker sqs",
      schema: [broker: :string, yes: :boolean],
      defaults: [broker: "sqs"],
      composes: ["ash.install", "ash_postgres.install"],
      installs:
        [
          {:ash, "~> 3.33"},
          {:ash_postgres, "~> 2.13"},
          {:bandit, "~> 1.12"},
          {:plug, "~> 1.18"},
          {:jason, "~> 1.4"}
        ] ++ Broker.deps(broker)
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    UpmarketStack.Gen.Worker.apply(igniter, igniter.args.options)
  end

  # `info/2` runs before igniter parses the options, so the broker is read
  # straight from argv: it selects the Broadway client dependency.
  defp broker_flag(["--broker", value | _rest]), do: value
  defp broker_flag(["--broker=" <> value | _rest]), do: value
  defp broker_flag([_arg | rest]), do: broker_flag(rest)
  defp broker_flag([]), do: nil
end
