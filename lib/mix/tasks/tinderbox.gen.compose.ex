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

  `--file-drop` (SaaS) adds a ClamAV daemon in the `scan` profile, for the file
  drop's scanner, and its variables to `.env.example`. `--plaid` (SaaS) adds the
  `PLAID_*` variables to `.env.example`, and no service: Plaid's sandbox is hosted.
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _source) do
    %Igniter.Mix.Task.Info{
      group: :tinderbox,
      example: "mix tinderbox.gen.compose --stack worker --broker sqs",
      schema: [
        stack: :string,
        broker: :string,
        db: :boolean,
        file_drop: :boolean,
        plaid: :boolean
      ],
      defaults: [stack: "api", broker: "sqs", db: true, file_drop: false, plaid: false]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Tinderbox.Gen.Compose.apply(igniter, igniter.args.options)
  end
end
