defmodule UpmarketStack.Gen.ComposeTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias UpmarketStack.Gen.Compose

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

  test "postgres is generated unless --no-db" do
    assert compose_content(:sqs) =~ "postgres:17-alpine"

    refute compose_content(:sqs, db: false) =~ "postgres:17-alpine"
    refute compose_content(:sqs, db: false, path: ".env.example") =~ "DATABASE_URL"
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

  defp source(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end
end
