defmodule Mix.Tasks.Tinderbox.Gen.Compose do
  @shortdoc "Generates docker-compose.yml and .env.example for the local backing services"

  @moduledoc """
  Generates `docker-compose.yml` and `.env.example`.

  The compose file contains only backing services — Postgres (unless `--no-db`),
  Floci (S3 + SQS) and floci-gcp (GCS + Pub/Sub) — plus RabbitMQ or Redpanda for
  the brokers that need them. The application runs on the host, so every
  endpoint is published on `localhost` and `FLOCI_HOSTNAME` is deliberately left
  unset (Floci then embeds `localhost` in the SQS queue URLs it generates).

  ```sh
  mix tinderbox.gen.compose --stack worker --broker sqs
  ```
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _source) do
    %Igniter.Mix.Task.Info{
      group: :tinderbox,
      example: "mix tinderbox.gen.compose --stack worker --broker sqs",
      schema: [stack: :string, broker: :string, db: :boolean],
      defaults: [stack: "api", broker: "sqs", db: true]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Tinderbox.Gen.Compose.apply(igniter, igniter.args.options)
  end
end
