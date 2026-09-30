defmodule Tinderbox.Broker do
  @moduledoc """
  The messaging technologies `mix tinderbox.gen.worker` can target.

  This module is the single source of truth for everything that varies between
  brokers: the Broadway client dependency, the extra `docker compose` service,
  and the environment variables the generated worker reads.
  """

  @type t :: :sqs | :pubsub | :rabbitmq | :kafka

  @brokers ~w(sqs pubsub rabbitmq kafka)

  @doc """
  Parses a `--broker` value, raising `Mix.raise/1` for anything unknown.
  """
  @spec parse!(String.t() | atom()) :: t()
  def parse!(value) when is_atom(value), do: parse!(Atom.to_string(value))

  def parse!(value) do
    case value do
      "sqs" ->
        :sqs

      "pubsub" ->
        :pubsub

      "rabbitmq" ->
        :rabbitmq

      "kafka" ->
        :kafka

      other ->
        Mix.raise("Unknown --broker #{other}. Must be one of: #{Enum.join(@brokers, ", ")}")
    end
  end

  @doc "The Broadway client dependency for the broker."
  @spec deps(t()) :: [{atom(), String.t()}]
  def deps(:sqs),
    do: [{:broadway, "~> 1.3"}, {:broadway_sqs, "~> 1.0"}, {:ex_aws_sqs, "~> 3.5"}]

  def deps(:pubsub), do: [{:broadway, "~> 1.3"}, {:broadway_cloud_pub_sub, "~> 1.0"}]
  def deps(:rabbitmq), do: [{:broadway, "~> 1.3"}, {:broadway_rabbitmq, "~> 0.8"}]
  def deps(:kafka), do: [{:broadway, "~> 1.3"}, {:broadway_kafka, "~> 0.7"}]

  @doc """
  Compose services the broker needs beyond Floci/floci-gcp.

  `:sqs` and `:pubsub` need none: Floci serves SQS, floci-gcp serves Pub/Sub.
  """
  @spec compose_services(t()) :: [:rabbitmq] | [:redpanda] | []
  def compose_services(:sqs), do: []
  def compose_services(:pubsub), do: []
  def compose_services(:rabbitmq), do: [:rabbitmq]
  def compose_services(:kafka), do: [:redpanda]

  @doc """
  The `NAME=value` entries this broker contributes to `.env.example`.

  `app_dash` is the OTP app name with `_` replaced by `-` — the same name the
  compose bootstrap scripts use for queues, topics and buckets.
  """
  @spec env_vars(t(), String.t()) :: [{String.t(), String.t()}]
  def env_vars(:sqs, app_dash) do
    [
      {"SQS_QUEUE_URL", "http://localhost:4566/000000000000/#{app_dash}-inbound"},
      {"SQS_PUBLISH_QUEUE_URL", "http://localhost:4566/000000000000/#{app_dash}-outbound"}
    ]
  end

  def env_vars(:pubsub, app_dash) do
    [
      {"PUBSUB_EMULATOR_HOST", "localhost:4588"},
      {"GCP_PROJECT_ID", "floci-local"},
      {"PUBSUB_SUBSCRIPTION", "#{app_dash}-inbound-sub"},
      {"PUBSUB_TOPIC", "#{app_dash}-outbound"},
      {"PUBSUB_ACCESS_TOKEN", "emulator"}
    ]
  end

  def env_vars(:rabbitmq, app_dash) do
    [
      {"RABBITMQ_URL", "amqp://guest:guest@localhost:5672"},
      {"RABBITMQ_QUEUE", "#{app_dash}-inbound"},
      {"RABBITMQ_EXCHANGE", app_dash},
      {"RABBITMQ_ROUTING_KEY", "#{app_dash}.outbound"},
      {"RABBITMQ_PUBLISH_QUEUE", "#{app_dash}-outbound"}
    ]
  end

  def env_vars(:kafka, app_dash) do
    [
      {"KAFKA_BROKERS", "localhost:19092"},
      {"KAFKA_CONSUMER_TOPIC", "#{app_dash}-inbound"},
      {"KAFKA_GROUP_ID", app_dash},
      {"KAFKA_PRODUCER_TOPIC", "#{app_dash}-outbound"}
    ]
  end

  @doc "Renders `env_vars/2` as the `.env.example` block for the broker."
  @spec env_block(t(), String.t()) :: String.t()
  def env_block(broker, app_dash) do
    broker
    |> env_vars(app_dash)
    |> Enum.map_join("\n", fn {name, value} -> "#{name}=#{value}" end)
  end

  @doc "The OTP app name in the form used for queue, topic and bucket names."
  @spec app_dash(atom() | String.t()) :: String.t()
  def app_dash(app), do: app |> to_string() |> String.replace("_", "-")
end
