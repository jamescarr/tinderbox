defmodule Mix.Tasks.Tinderbox.Gen.Mise do
  @shortdoc "Generates .mise.toml (toolchain, local environment, dev-loop tasks)"

  @moduledoc """
  Generates `.mise.toml`: Elixir/Erlang pins (and CMake for the Kafka worker), the
  local environment from `.env.example`, and the tasks `up`, `down`, `setup`,
  `dev`, `test`, `check` (plus `health` for the worker).

  ```sh
  mix tinderbox.gen.mise --stack worker --broker sqs
  ```

  Pass `--no-compose` when no `docker-compose.yml` was generated: the `up`/`down`
  tasks and the `depends = ["up"]` links are then left out.
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _source) do
    %Igniter.Mix.Task.Info{
      group: :tinderbox,
      example: "mix tinderbox.gen.mise --stack worker --broker sqs",
      schema: [stack: :string, broker: :string, compose: :boolean, db: :boolean],
      defaults: [stack: "api", broker: "sqs", compose: true, db: true]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Tinderbox.Gen.Mise.apply(igniter, igniter.args.options)
  end
end
