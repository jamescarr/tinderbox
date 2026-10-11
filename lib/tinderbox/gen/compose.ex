defmodule Tinderbox.Gen.Compose do
  @moduledoc """
  Generates `docker-compose.yml` and `.env.example`.

  Every stack gets the same backing services — Postgres (when `db?`), Floci for
  S3/SQS and floci-gcp for GCS/Pub/Sub — plus the broker-specific service the
  worker stack needs. The SaaS stack always adds NATS (its event bus), Dex (a
  local OIDC provider, configured by `docker/dex/config.yaml`) and Mailpit (an
  SMTP sink with a web inbox). The application itself is *not* a compose service: it runs
  on the host under `mix`, so every endpoint is published on `localhost`.

  The compose file is rendered from `priv/templates`; `.env.example` comes from
  `Tinderbox.Env`, the same data `Tinderbox.Gen.Mise` puts in `.mise.toml`.
  Compose publishes the host ports from the environment (`PGPORT`, and for the
  SaaS stack `SMTP_PORT`/`MAILPIT_UI_PORT`), and `config/dev.exs` and
  `config/test.exs` read `PGPORT` for the repo, so moving Postgres is one line in
  `.mise.local.toml`. `.env` and `docker-compose.override.yml` are added to
  `.gitignore`: they are the copies developers edit.
  Called by `mix tinderbox.gen.compose`.
  """

  alias Tinderbox.Broker
  alias Tinderbox.Env
  alias Tinderbox.Gen

  @spec apply(Igniter.t(), Keyword.t()) :: Igniter.t()
  def apply(igniter, opts) do
    app = Igniter.Project.Application.app_name(igniter)
    module = Igniter.Project.Module.module_name_prefix(igniter)
    broker = Broker.parse!(Keyword.get(opts, :broker) || "sqs")
    db? = Keyword.get(opts, :db, true)
    stack = Keyword.get(opts, :stack, "api")

    assigns = [
      app: app,
      app_dash: Broker.app_dash(app),
      db?: db?,
      stack: stack,
      extra_service: List.first(Broker.compose_services(broker))
    ]

    env =
      Env.sections(
        app: app,
        module: module,
        stack: stack,
        broker: broker,
        db?: db?
      )

    igniter
    |> Igniter.copy_template(
      Gen.template_path("docker-compose.yml.eex"),
      "docker-compose.yml",
      assigns
    )
    |> add_dex_config(stack, assigns, module)
    |> Igniter.create_new_file(".env.example", Env.dotenv(env))
    |> configure_repo_port(app, module, db?)
    |> Gen.ignore([".env", "docker-compose.override.yml"])
  end

  # Ecto's Postgres pool defaults the port to 5432 itself (only `mix ecto.create`
  # falls back to PGPORT), so the published port has to be read explicitly.
  # Re-running replaces the value with the same code.
  defp configure_repo_port(igniter, app, module, true) do
    port = Sourceror.parse_string!(~s|String.to_integer(System.get_env("PGPORT", "5432"))|)
    repo = Module.concat(module, "Repo")

    Enum.reduce(["dev.exs", "test.exs"], igniter, fn file, igniter ->
      Igniter.Project.Config.configure(igniter, file, app, [repo, :port], {:code, port})
    end)
  end

  defp configure_repo_port(igniter, _app, _module, false), do: igniter

  # The SaaS stack's local OIDC provider reads its static client and user from
  # this file, which is mounted into the `dex` service.
  defp add_dex_config(igniter, "saas", assigns, module) do
    Igniter.copy_template(
      igniter,
      Gen.template_path("saas/dex-config.yaml.eex"),
      "docker/dex/config.yaml",
      Keyword.put(assigns, :module, inspect(module))
    )
  end

  defp add_dex_config(igniter, _stack, _assigns, _module), do: igniter
end
