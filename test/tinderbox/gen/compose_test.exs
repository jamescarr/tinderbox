defmodule Tinderbox.Gen.ComposeTest do
  use ExUnit.Case, async: true

  import Igniter.Test
  import Tinderbox.Test.SourceHelpers, only: [source: 2]

  alias Tinderbox.Gen.Compose

  test "writes docker-compose.yml and .env.example" do
    igniter = compose(:sqs)

    assert_creates(igniter, "docker-compose.yml")
    assert_creates(igniter, ".env.example")
  end

  test "always ships both emulators and their bootstrap jobs" do
    content = compose_content(:sqs)

    assert content =~ "floci/floci:latest"
    assert content =~ "floci/floci-gcp:latest"
    assert content =~ "aws s3 mb s3://test-local"
    assert content =~ "aws sqs create-queue --queue-name test-inbound"
    assert content =~ "aws sqs create-queue --queue-name test-outbound"
    assert content =~ "topics/test-inbound"
    assert content =~ "subscriptions/test-inbound-sub"
  end

  test "does not set FLOCI_HOSTNAME so generated queue URLs use localhost" do
    refute compose_content(:sqs) =~ "FLOCI_HOSTNAME:"
  end

  test "adds no broker service for the emulator-served brokers" do
    for broker <- [:sqs, :pubsub] do
      content = compose_content(broker)

      refute content =~ "rabbitmq:4-management-alpine"
      refute content =~ "redpanda"
    end
  end

  test "kafka adds redpanda and creates both topics" do
    content = compose_content(:kafka)

    assert content =~ "docker.redpanda.com/redpandadata/redpanda:v26.2.3"
    assert content =~ "rpk topic create test-inbound -X brokers=redpanda:9092"
    assert content =~ "rpk topic create test-outbound -X brokers=redpanda:9092"
    refute content =~ "rabbitmq:4-management-alpine"
  end

  test "rabbitmq adds the rabbitmq service" do
    content = compose_content(:rabbitmq)

    assert content =~ "rabbitmq:4-management-alpine"
    refute content =~ "redpanda"
  end

  test "nats adds JetStream; only the worker stack gets the bootstrap job its `ready` waits for" do
    content = compose_content(:nats)

    assert content =~ "image: nats:2.15-alpine"
    assert content =~ ~s(command: ["--jetstream")
    assert content =~ "  nats-data:"
    refute content =~ "nats-bootstrap"
    refute content =~ "rabbitmq:4-management-alpine"

    worker = compose_content(:nats, stack: "worker")

    assert worker =~ "natsio/nats-box:0.20.0"
    assert worker =~ ~s(stream add test-inbound --subjects "test.inbound")
    assert worker =~ ~s(stream add test-outbound --subjects "test.outbound")
    assert worker =~ "consumer add test-inbound test-worker --pull"
    assert worker =~ ~r/nats-bootstrap:\n    image/

    ready = worker |> String.split("\n  ready:\n", parts: 2) |> List.last()
    assert ready =~ ~r/nats-bootstrap:\s+condition: service_completed_successfully/
  end

  test "saas adds Dex, Mailpit and NATS, and Dex's config next to them" do
    igniter = compose(:nats, stack: "saas")
    content = source(igniter, "docker-compose.yml")

    assert content =~ "image: dexidp/dex:v2.46.0"
    assert content =~ "./docker/dex/config.yaml:/etc/dex/config.yaml:ro"
    assert content =~ "image: axllent/mailpit:v1.31"
    assert content =~ ~s|"${SMTP_PORT:-1025}:1025"|
    assert content =~ ~s|"${MAILPIT_UI_PORT:-8025}:8025"|
    assert content =~ "image: nats:2.15-alpine"
    # The application creates its own stream (`Test.Events.StreamBootstrap`).
    refute content =~ "nats-bootstrap"

    dex = source(igniter, "docker/dex/config.yaml")

    assert dex =~ "issuer: http://localhost:5556/dex"
    assert dex =~ "- id: test"
    assert dex =~ "secret: test-dev-secret"
    assert dex =~ "http://localhost:4000/auth/user/sso/callback"
    assert dex =~ "email: admin@example.com"
  end

  test "only the saas stack gets Dex and Mailpit" do
    for stack <- ["api", "worker"] do
      content = compose_content(:nats, stack: stack)

      refute content =~ "dexidp/dex"
      refute content =~ "mailpit"
      refute_creates(compose(:nats, stack: stack), "docker/dex/config.yaml")
    end
  end

  test "a running service waits for every bootstrap job to complete, so `up --wait` exits 0" do
    # Compose fails `up --wait` when a job container merely exits (even with
    # status 0) unless a running service depends on it completing.
    for broker <- [:sqs, :pubsub, :rabbitmq, :kafka] do
      compose = compose_content(broker)
      jobs = ~r/^  ([a-z-]+-bootstrap):$/m |> Regex.scan(compose) |> Enum.map(&List.last/1)

      ready =
        compose
        |> String.split("\n  ready:\n", parts: 2)
        |> List.last()
        |> String.split(~r/^volumes:/m, parts: 2)
        |> hd()

      assert "aws-bootstrap" in jobs and "gcp-bootstrap" in jobs
      assert ready =~ ~s(entrypoint: ["sleep", "infinity"]), "#{broker}: ready must stay up"

      # `sleep` as PID 1 ignores SIGTERM: without an init, `docker compose down`
      # waits out Docker's 10s stop timeout (measured 10.4s vs 0.3s).
      assert ready =~ "init: true", "#{broker}: ready needs an init to stop promptly"

      for job <- jobs do
        assert ready =~ ~r/#{job}:\s+condition: service_completed_successfully/,
               "#{broker}: nothing waits for #{job}"
      end
    end

    assert compose_content(:kafka) =~ "redpanda-bootstrap:\n    image"
    refute compose_content(:sqs) =~ "redpanda-bootstrap"
  end

  test "postgres is generated unless --no-db, on the host port PGPORT names" do
    assert compose_content(:sqs) =~ "postgres:17-alpine"
    assert compose_content(:sqs) =~ ~s|"${PGPORT:-5432}:5432"|
    assert compose_content(:sqs, path: ".env.example") =~ "export PGPORT=5432"

    refute compose_content(:sqs, db: false) =~ "postgres:17-alpine"
    refute compose_content(:sqs, db: false, path: ".env.example") =~ "DATABASE_URL"
    refute compose_content(:sqs, db: false, path: ".env.example") =~ "PGPORT"
  end

  test "the repo's dev and test config read PGPORT, inside the existing block and once" do
    port = ~s|port: String.to_integer(System.get_env("PGPORT", "5432"))|

    igniter =
      [
        files: %{
          "config/dev.exs" =>
            ~s|import Config\n\nconfig :test, Test.Repo,\n  database: "test_dev"\n|
        }
      ]
      |> test_project()
      |> Compose.apply(broker: "sqs")

    dev = source(igniter, "config/dev.exs")

    assert dev =~ port
    assert [_one] = Regex.scan(~r/config :test, Test\.Repo/, dev)
    assert source(igniter, "config/test.exs") =~ port

    assert source(Compose.apply(igniter, broker: "sqs"), "config/dev.exs") == dev
    refute_creates(compose(:sqs, db: false), "config/dev.exs")
  end

  test "the worker .env.example carries the health port and the broker block" do
    env = compose_content(:sqs, stack: "worker", path: ".env.example")

    assert env =~ "HEALTH_PORT=4001"
    assert env =~ "SQS_QUEUE_URL=http://localhost:4566/000000000000/test-inbound"
    assert env =~ "SQS_PUBLISH_QUEUE_URL=http://localhost:4566/000000000000/test-outbound"
  end

  test "the api .env.example has no worker block" do
    env = compose_content(:sqs, stack: "api", path: ".env.example")

    refute env =~ "HEALTH_PORT"
    refute env =~ "SQS_QUEUE_URL"
  end

  test "the emulator endpoints and the storage backend are always in .env.example" do
    env = compose_content(:pubsub, stack: "worker", path: ".env.example")

    assert env =~ "AWS_ENDPOINT_URL=http://localhost:4566"
    assert env =~ "STORAGE_EMULATOR_HOST=http://localhost:4588"
    assert env =~ "STORAGE_BACKEND=s3"
    assert env =~ "Test.Storage"
    assert env =~ "GCS_BUCKET=test-local"
  end

  test ".env.example exports every variable, so a plain `source` reaches mix" do
    env = compose_content(:sqs, stack: "worker", path: ".env.example")

    assignments =
      env
      |> String.split("\n")
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    assert assignments != []
    assert Enum.all?(assignments, &String.starts_with?(&1, "export "))
    assert env =~ "export HEALTH_PORT=4001"
  end

  test "keeps the developer's .env and compose override out of git, and leaves .env.example tracked" do
    gitignore = source(compose(:sqs), ".gitignore")

    assert gitignore =~ ~r/^\.env$/m
    assert gitignore =~ ~r/^docker-compose\.override\.yml$/m
    refute gitignore =~ ".env.example"
  end

  test "raises on an unknown broker" do
    assert_raise Mix.Error, ~r/Unknown --broker fog/, fn ->
      Compose.apply(test_project(), broker: "fog")
    end
  end

  defp compose(broker, opts \\ []) do
    test_project()
    |> Compose.apply([broker: to_string(broker)] ++ Keyword.delete(opts, :path))
  end

  defp compose_content(broker, opts \\ []) do
    path = Keyword.get(opts, :path, "docker-compose.yml")
    source(compose(broker, opts), path)
  end
end
