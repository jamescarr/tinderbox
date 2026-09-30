defmodule UpmarketStack.Gen.Compose do
  @moduledoc """
  Generates `docker-compose.yml` and `.env.example`.

  Both stacks get the same backing services — Postgres (when `db?`), Floci for
  S3/SQS and floci-gcp for GCS/Pub/Sub — plus the broker-specific service the
  worker stack needs. The application itself is *not* a compose service: it runs
  on the host under `mix`, so every endpoint is published on `localhost`.

  All file content is rendered from `priv/templates`; this module only computes
  the assigns. Called by `mix upmarket.gen.compose`.
  """

  alias UpmarketStack.Broker
  alias UpmarketStack.Gen

  @spec apply(Igniter.t(), Keyword.t()) :: Igniter.t()
  def apply(igniter, opts) do
    app = Igniter.Project.Application.app_name(igniter)
    app_dash = Broker.app_dash(app)
    broker = Broker.parse!(Keyword.get(opts, :broker) || "sqs")

    assigns = [
      app: app,
      app_dash: app_dash,
      module: Igniter.Project.Module.module_name_prefix(igniter),
      stack: Keyword.get(opts, :stack, "api"),
      broker: broker,
      broker_env: Broker.env_block(broker, app_dash),
      db?: Keyword.get(opts, :db, true),
      extra_service: List.first(Broker.compose_services(broker))
    ]

    igniter
    |> Igniter.copy_template(
      Gen.template_path("docker-compose.yml.eex"),
      "docker-compose.yml",
      assigns
    )
    |> Igniter.copy_template(Gen.template_path("env.example.eex"), ".env.example", assigns)
  end
end
