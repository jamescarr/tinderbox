defmodule Tinderbox.Gen.WorkerTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Tinderbox.Broker
  alias Tinderbox.Gen.Worker

  @brokers [:sqs, :pubsub, :rabbitmq, :kafka]

  @producers [
    sqs: "BroadwaySQS.Producer",
    pubsub: "BroadwayCloudPubSub.Producer",
    rabbitmq: "BroadwayRabbitMQ.Producer",
    kafka: "BroadwayKafka.Producer"
  ]

  @publishers [
    sqs: "ExAws.SQS.send_message(config[:publish_queue_url]",
    pubsub: ~S(topics/#{config[:topic]}:publish),
    rabbitmq: "Test.Publisher.Connection.publish(config[:routing_key]",
    kafka: "Test.Publisher.KafkaClient.client()"
  ]

  test "every broker creates the worker modules" do
    for broker <- @brokers do
      igniter = worker(broker)

      assert_creates(igniter, "lib/test/pipeline.ex")
      assert_creates(igniter, "lib/test/processing.ex")
      assert_creates(igniter, "lib/test/publisher.ex")
      assert_creates(igniter, "lib/test/health.ex")
      assert_creates(igniter, "lib/test/inbox.ex")
      assert_creates(igniter, "lib/test/inbox/message.ex")
      assert_creates(igniter, "lib/test/storage.ex")
      assert_creates(igniter, "config/runtime.exs")
    end
  end

  test "the pipeline names the producer of the selected broker only" do
    for {broker, producer} <- @producers do
      pipeline = source(worker(broker), "lib/test/pipeline.ex")

      assert pipeline =~ producer

      for {other_broker, other_producer} <- @producers, other_broker != broker do
        refute pipeline =~ other_producer,
               "#{broker} pipeline should not reference #{other_producer}"
      end
    end
  end

  test "the publisher uses the outbound endpoint of the selected broker" do
    for {broker, expected} <- @publishers do
      assert source(worker(broker), "lib/test/publisher.ex") =~ expected
    end
  end

  test "broker-specific connection processes are only created where needed" do
    assert_creates(worker(:rabbitmq), "lib/test/publisher/connection.ex")
    refute_creates(worker(:rabbitmq), "lib/test/publisher/kafka_client.ex")

    assert_creates(worker(:kafka), "lib/test/publisher/kafka_client.ex")
    refute_creates(worker(:kafka), "lib/test/publisher/connection.ex")

    refute_creates(worker(:sqs), "lib/test/publisher/connection.ex")
  end

  test "the children list runs Repo, the broker connection, the pipeline, then health" do
    application = source(worker(:rabbitmq, files: repo_files()), "lib/test/application.ex")

    assert order(application, "Test.Repo") < order(application, "Test.Publisher.Connection")
    assert order(application, "Test.Publisher.Connection") < order(application, "Test.Pipeline")
    assert order(application, "Test.Pipeline") < order(application, "{Bandit")

    kafka = source(worker(:kafka, files: repo_files()), "lib/test/application.ex")
    assert order(kafka, "Test.Repo") < order(kafka, "Test.Publisher.KafkaClient")
    assert order(kafka, "Test.Publisher.KafkaClient") < order(kafka, "Test.Pipeline")
  end

  test "the health endpoint reads its port from the runtime config" do
    application = source(worker(:sqs, files: repo_files()), "lib/test/application.ex")

    assert application =~ ~s|port: Application.fetch_env!(:test, :health_port)|
    assert source(worker(:sqs), "lib/test/health.ex") =~ "Process.whereis(Test.Pipeline)"
  end

  test "the idempotency store is registered as an Ash domain" do
    config = source(worker(:sqs), "config/config.exs")

    assert config =~ "ash_domains"
    assert config =~ "Test.Inbox"
  end

  test "the runtime config reads every env var the broker documents, with its documented default" do
    for broker <- @brokers do
      runtime = source(worker(broker), "config/runtime.exs")

      for {name, default} <- Broker.env_vars(broker, "test") do
        # Allow the formatter to wrap the call across lines.
        pattern = ~r/System\.get_env\(\s*"#{name}",\s*"#{Regex.escape(default)}"\s*\)/

        assert runtime =~ pattern,
               "#{broker}: runtime config does not read #{name} with the documented default"
      end

      assert runtime =~ "health_port"
    end
  end

  test "the runtime config never requires an env var at load time" do
    for broker <- @brokers do
      runtime = source(worker(broker), "config/runtime.exs")

      refute runtime =~ "fetch_env!",
             "#{broker}: runtime.exs must load without the environment being sourced"
    end
  end

  test "the pipeline persists the idempotency record before publishing" do
    pipeline = source(worker(:sqs), "lib/test/pipeline.ex")

    assert pipeline =~ "Ash.get(InboxMessage, %{message_id: id}"
    # The resource has no primary create action, so `Ash.create/3` must be given
    # the action explicitly.
    assert pipeline =~ "Ash.create(InboxMessage, attributes, action: :record, domain: Inbox)"
    assert pipeline =~ "private_vars[:constraint_type] == :unique"
    assert pipeline =~ "Ash.Changeset.for_update(:update, %{processed_at: DateTime.utc_now()})"

    assert order(pipeline, "Ash.create(InboxMessage") <
             order(pipeline, "Publisher.publish(result")
  end

  test "the notice is mise-first by default and health is a mise task" do
    igniter = worker(:sqs)

    assert_has_notice(igniter, &(&1 =~ "mise trust && mise run dev"))
    assert_has_notice(igniter, &(&1 =~ "mix run --no-halt"))
    assert_has_notice(igniter, &(&1 =~ "mise run health"))
  end

  test "without mise the notice spells out docker compose, a sourced .env and the server" do
    igniter = Worker.apply(test_project(), broker: :sqs, mise: false)

    assert_has_notice(
      igniter,
      &(&1 =~ "docker compose up -d --wait && cp .env.example .env && . ./.env && mix ash.setup")
    )

    refute Enum.any?(igniter.notices, &(&1 =~ "mise"))
  end

  test "kafka warns about cmake" do
    assert_has_notice(worker(:kafka), &(&1 =~ "CMake"))
  end

  defp worker(broker, opts \\ []) do
    test_project(Keyword.take(opts, [:files]))
    |> Worker.apply(broker: broker)
  end

  defp repo_files do
    %{
      "lib/test/application.ex" => """
      defmodule Test.Application do
        @moduledoc false

        use Application

        @impl true
        def start(_type, _args) do
          children = [
            Test.Repo
          ]

          opts = [strategy: :one_for_one, name: Test.Supervisor]
          Supervisor.start_link(children, opts)
        end
      end
      """,
      "lib/test/repo.ex" => """
      defmodule Test.Repo do
        use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres
      end
      """
    }
  end

  defp source(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  defp order(string, substring), do: :binary.match(string, substring) |> elem(0)
end
