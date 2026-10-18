defmodule Tinderbox.Gen.SaasDeployTest do
  # The Ash domain list is read from the application env, which is global.
  use ExUnit.Case, async: false

  import Igniter.Test
  import Tinderbox.Test.SaasFixtures
  import Tinderbox.Test.SourceHelpers, only: [source: 2]

  alias Tinderbox.Gen.Saas

  setup_all do
    Application.put_env(:test, :ash_domains, [Test.Accounts])
    on_exit(fn -> Application.delete_env(:test, :ash_domains) end)

    {:ok, igniter: Saas.apply(saas_project(), [])}
  end

  test "fly.toml runs the release image, migrates first and checks /health", %{
    igniter: igniter
  } do
    fly = source(igniter, "fly.toml")

    assert fly =~ ~s(app = "test")
    assert fly =~ ~s(PHX_HOST = "test.fly.dev")
    assert fly =~ ~s(PORT = "8080")
    assert fly =~ "internal_port = 8080"
    assert fly =~ ~s(path = "/health")

    # Migrations bypass PgBouncer when the direct URL is set.
    assert fly =~ "DATABASE_URL=${DIRECT_DATABASE_URL:-$DATABASE_URL} exec /app/bin/migrate"
  end

  test "fly.toml sets what the runtime config reads for Fly's private network and services", %{
    igniter: igniter
  } do
    fly = source(igniter, "fly.toml")
    runtime = source(igniter, "config/runtime.exs")

    for {name, value} <- [
          {"NATS_HOST", "test-nats.internal"},
          {"NATS_INET6", "true"},
          {"DATABASE_POOLER", "pgbouncer"},
          {"ECTO_IPV6", "true"},
          {"S3_BUCKET", "test-storage"},
          {"AWS_ENDPOINT_URL", "https://fly.storage.tigris.dev"},
          {"SMTP_USERNAME", "resend"},
          {"SSO_REDIRECT_URI", "https://test.fly.dev/auth"}
        ] do
      assert fly =~ ~s(#{name} = "#{value}")
      assert runtime =~ ~s("#{name}"), "config/runtime.exs does not read #{name}"
    end

    # Secrets are set with flyctl, never written down.
    refute fly =~ "SECRET_KEY_BASE ="
  end

  test "NATS is its own app, on a volume, listening on the private network only", %{
    igniter: igniter
  } do
    nats = source(igniter, "fly/nats/fly.toml")

    assert nats =~ ~s(app = "test-nats")
    assert nats =~ ~s(image = "nats:2.11-alpine")
    assert nats =~ "--jetstream --store_dir /data --addr ::"
    assert nats =~ ~s(source = "nats_data")
    refute nats =~ "http_service"
    refute nats =~ "[[services]]"
  end

  test "the README has the one-time setup and the deploy loop", %{igniter: igniter} do
    readme = source(igniter, "README.md")

    assert readme =~ "## Deploying to Fly.io"
    assert readme =~ "flyctl volumes create nats_data --app test-nats"
    assert readme =~ "flyctl mpg attach <cluster-id> --app test"
    assert readme =~ "flyctl storage create --name test-storage --app test"
    assert readme =~ "mise run deploy"
  end

  test "--deploy none writes none of it" do
    igniter = Saas.apply(saas_project(), deploy: "none")

    refute_creates(igniter, "fly.toml")
    refute_creates(igniter, "fly/nats/fly.toml")
    refute source(igniter, "README.md") =~ "Fly.io"
  end

  test "an unknown --deploy is refused" do
    assert_raise Mix.Error, ~r/Unknown --deploy "heroku". Must be "fly" or "none"/, fn ->
      Saas.apply(saas_project(), deploy: "heroku")
    end
  end
end
