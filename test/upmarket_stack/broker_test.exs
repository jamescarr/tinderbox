defmodule UpmarketStack.BrokerTest do
  use ExUnit.Case, async: true

  alias UpmarketStack.Broker

  @brokers ~w(sqs pubsub rabbitmq kafka)

  test "parse!/1 accepts the documented brokers" do
    for broker <- @brokers do
      assert Broker.parse!(broker) == String.to_existing_atom(broker)
    end
  end

  test "parse!/1 raises on an unknown broker" do
    assert_raise Mix.Error,
                 ~r/Unknown --broker fog\. Must be one of: sqs, pubsub, rabbitmq, kafka/,
                 fn -> Broker.parse!("fog") end
  end

  test "deps/1 pairs broadway with the client for the broker" do
    assert {:broadway_sqs, _} = List.keyfind(Broker.deps(:sqs), :broadway_sqs, 0)

    assert {:broadway_cloud_pub_sub, _} =
             List.keyfind(Broker.deps(:pubsub), :broadway_cloud_pub_sub, 0)

    assert {:broadway_rabbitmq, _} = List.keyfind(Broker.deps(:rabbitmq), :broadway_rabbitmq, 0)
    assert {:broadway_kafka, _} = List.keyfind(Broker.deps(:kafka), :broadway_kafka, 0)

    for broker <- [:sqs, :pubsub, :rabbitmq, :kafka] do
      assert {:broadway, "~> 1.3"} = List.keyfind(Broker.deps(broker), :broadway, 0)
    end
  end

  test "deps/1 adds ex_aws_sqs only for sqs (the publisher uses ExAws.SQS)" do
    assert {:ex_aws_sqs, _} = List.keyfind(Broker.deps(:sqs), :ex_aws_sqs, 0)

    for broker <- [:pubsub, :rabbitmq, :kafka] do
      refute List.keyfind(Broker.deps(broker), :ex_aws_sqs, 0)
    end
  end

  test "compose_services/1 only adds a service for self-hosted brokers" do
    assert Broker.compose_services(:sqs) == []
    assert Broker.compose_services(:pubsub) == []
    assert Broker.compose_services(:rabbitmq) == [:rabbitmq]
    assert Broker.compose_services(:kafka) == [:redpanda]
  end

  test "env_vars/2 documents the keys each broker reads" do
    assert env_keys(:sqs) == ["SQS_QUEUE_URL", "SQS_PUBLISH_QUEUE_URL"]

    assert env_keys(:pubsub) == [
             "PUBSUB_EMULATOR_HOST",
             "GCP_PROJECT_ID",
             "PUBSUB_SUBSCRIPTION",
             "PUBSUB_TOPIC",
             "PUBSUB_ACCESS_TOKEN"
           ]

    assert env_keys(:rabbitmq) == [
             "RABBITMQ_URL",
             "RABBITMQ_QUEUE",
             "RABBITMQ_EXCHANGE",
             "RABBITMQ_ROUTING_KEY",
             "RABBITMQ_PUBLISH_QUEUE"
           ]

    assert env_keys(:kafka) == [
             "KAFKA_BROKERS",
             "KAFKA_CONSUMER_TOPIC",
             "KAFKA_GROUP_ID",
             "KAFKA_PRODUCER_TOPIC"
           ]
  end

  test "env_vars/2 names queues, topics and buckets after the dashed app name" do
    assert {"SQS_QUEUE_URL", "http://localhost:4566/000000000000/demo-worker-inbound"} in Broker.env_vars(
             :sqs,
             "demo-worker"
           )

    assert {"KAFKA_CONSUMER_TOPIC", "demo-worker-inbound"} in Broker.env_vars(
             :kafka,
             "demo-worker"
           )

    assert {"PUBSUB_SUBSCRIPTION", "demo-worker-inbound-sub"} in Broker.env_vars(
             :pubsub,
             "demo-worker"
           )

    assert {"RABBITMQ_PUBLISH_QUEUE", "demo-worker-outbound"} in Broker.env_vars(
             :rabbitmq,
             "demo-worker"
           )
  end

  test "env_block/2 renders NAME=value lines" do
    assert Broker.env_block(:kafka, "demo") == """
           KAFKA_BROKERS=localhost:19092
           KAFKA_CONSUMER_TOPIC=demo-inbound
           KAFKA_GROUP_ID=demo
           KAFKA_PRODUCER_TOPIC=demo-outbound\
           """
  end

  test "app_dash/1 converts underscores to dashes" do
    assert Broker.app_dash(:demo_worker) == "demo-worker"
  end

  defp env_keys(broker) do
    broker
    |> Broker.env_vars("test")
    |> Enum.map(&elem(&1, 0))
  end
end
