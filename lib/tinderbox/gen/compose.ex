defmodule Tinderbox.Gen.Compose do
  @moduledoc """
  Generates `docker-compose.yml` and `.env.example`.

  Both stacks get the same backing services — Postgres (when `db?`), Floci for
  S3/SQS and floci-gcp for GCS/Pub/Sub — plus the broker-specific service the
  worker stack needs. The application itself is *not* a compose service: it runs
  on the host under `mix`, so every endpoint is published on `localhost`.

  The compose file is rendered from `priv/templates`; `.env.example` comes from
  `Tinderbox.Env`, the same data `Tinderbox.Gen.Mise` puts in `.mise.toml`.
  `.env` is added to `.gitignore` because it is the copy developers edit.
  Called by `mix tinderbox.gen.compose`.
  """

  alias Tinderbox.Broker
  alias Tinderbox.Env
  alias Tinderbox.Gen

  @spec apply(Igniter.t(), Keyword.t()) :: Igniter.t()
  def apply(igniter, opts) do
    app = Igniter.Project.Application.app_name(igniter)
    broker = Broker.parse!(Keyword.get(opts, :broker) || "sqs")
    db? = Keyword.get(opts, :db, true)

    assigns = [
      app: app,
      app_dash: Broker.app_dash(app),
      db?: db?,
      extra_service: List.first(Broker.compose_services(broker))
    ]

    env =
      Env.sections(
        app: app,
        module: Igniter.Project.Module.module_name_prefix(igniter),
        stack: Keyword.get(opts, :stack, "api"),
        broker: broker,
        db?: db?
      )

    igniter
    |> Igniter.copy_template(
      Gen.template_path("docker-compose.yml.eex"),
      "docker-compose.yml",
      assigns
    )
    |> Igniter.create_new_file(".env.example", Env.dotenv(env))
    |> Gen.ignore([".env"])
  end
end
