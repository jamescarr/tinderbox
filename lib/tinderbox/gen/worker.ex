defmodule Tinderbox.Gen.Worker do
  @moduledoc """
  Generates the worker stack: a headless OTP daemon that consumes from one
  messaging endpoint of `<broker>`, records the message id in an
  Ash/AshPostgres idempotency store, and publishes the transformed message to a
  second endpoint of the same broker.

  Igniter installs the Ash packages and runs `ash.install` /
  `ash_postgres.install` *before* this module runs (they are declared in
  `Mix.Tasks.Tinderbox.Gen.Worker.info/2`), so `<App>.Repo` already exists and is
  supervised. This module adds:

  * the object storage wiring both stacks share (`Tinderbox.Gen.Storage`),
  * the idempotency store (`<App>.Inbox` + `<App>.Inbox.Message`),
  * the Broadway pipeline (a `Gnat.Jetstream.PullConsumer` for `--broker nats`), the
    processing seam, and the broker-specific publisher (plus its connection
    process for RabbitMQ / `:brod` client for Kafka / the Gnat connection
    supervisor for NATS),
  * the health endpoint and the supervisor children,
  * the runtime config the pipeline and the health endpoint read.
  """

  alias Tinderbox.Broker
  alias Tinderbox.Gen
  alias Tinderbox.Gen.Storage

  @spec apply(Igniter.t(), Keyword.t()) :: Igniter.t()
  def apply(igniter, opts) do
    broker = Broker.parse!(Keyword.get(opts, :broker) || "sqs")
    app = Igniter.Project.Application.app_name(igniter)
    prefix = Igniter.Project.Module.module_name_prefix(igniter)

    assigns = [
      app: app,
      app_dash: Broker.app_dash(app),
      broker: broker,
      inbox: Module.concat(prefix, Inbox),
      message: Module.concat(prefix, Inbox.Message),
      pipeline: Module.concat(prefix, Pipeline),
      processing: Module.concat(prefix, Processing),
      publisher: Module.concat(prefix, Publisher),
      connection: Module.concat(prefix, Publisher.Connection),
      kafka_client: Module.concat(prefix, Publisher.KafkaClient),
      health: Module.concat(prefix, Health),
      repo: Module.concat(prefix, Repo)
    ]

    igniter
    |> Storage.apply(opts)
    |> add_inbox(assigns)
    |> add_modules(assigns)
    |> add_children(assigns)
    |> add_runtime_config(assigns)
    |> add_notices(opts, broker)
  end

  defp add_inbox(igniter, assigns) do
    igniter
    |> Gen.create_modules(
      [
        {assigns[:inbox], "worker/inbox.ex.eex"},
        {assigns[:message], "worker/inbox_message.ex.eex"}
      ],
      assigns
    )
    |> Igniter.Project.Config.configure(
      "config.exs",
      assigns[:app],
      [:ash_domains],
      [assigns[:inbox]],
      updater: fn zipper -> Igniter.Code.List.prepend_new_to_list(zipper, assigns[:inbox]) end
    )
  end

  defp add_modules(igniter, assigns) do
    igniter
    |> Gen.create_modules(
      [
        {assigns[:pipeline], "worker/pipeline.ex.eex"},
        {assigns[:processing], "worker/processing.ex.eex"},
        {assigns[:publisher], "worker/publisher.ex.eex"},
        {assigns[:health], "worker/health.ex.eex"}
      ],
      assigns
    )
    |> add_broker_modules(assigns)
  end

  defp add_broker_modules(igniter, assigns) do
    case assigns[:broker] do
      :rabbitmq ->
        Igniter.Project.Module.create_module(
          igniter,
          assigns[:connection],
          Gen.render_template("worker/publisher_connection.ex.eex", assigns)
        )

      :kafka ->
        Igniter.Project.Module.create_module(
          igniter,
          assigns[:kafka_client],
          Gen.render_template("worker/publisher_kafka_client.ex.eex", assigns)
        )

      _sqs_or_pubsub ->
        igniter
    end
  end

  # Children are inserted as early as `after:` allows, so the broker connection,
  # the pipeline and the health endpoint end up in that order behind the
  # `<App>.Repo` child `ash_postgres.install` added.
  defp add_children(igniter, assigns) do
    repo = assigns[:repo]
    pipeline = assigns[:pipeline]

    case broker_child(assigns) do
      nil ->
        igniter
        |> Igniter.Project.Application.add_new_child(pipeline, after: [repo])
        |> add_health_child(assigns, [repo, pipeline])

      {module, _opts} = child ->
        igniter
        |> Igniter.Project.Application.add_new_child(child, after: [repo])
        |> Igniter.Project.Application.add_new_child(pipeline, after: [repo, module])
        |> add_health_child(assigns, [repo, module, pipeline])

      module when is_atom(module) ->
        igniter
        |> Igniter.Project.Application.add_new_child(module, after: [repo])
        |> Igniter.Project.Application.add_new_child(pipeline, after: [repo, module])
        |> add_health_child(assigns, [repo, module, pipeline])
    end
  end

  defp broker_child(assigns) do
    case assigns[:broker] do
      :rabbitmq ->
        {assigns[:connection], []}

      :kafka ->
        assigns[:kafka_client]

      # The connection settings come from the runtime config, so they are handed
      # over as code (same technique as the health child's port).
      :nats ->
        settings =
          Sourceror.parse_string!("Application.fetch_env!(#{inspect(assigns[:app])}, :nats)")

        {Gnat.ConnectionSupervisor, {:code, settings}}

      _sqs_or_pubsub ->
        nil
    end
  end

  defp add_health_child(igniter, assigns, after_modules) do
    # The port comes from the runtime config, so it is handed to
    # `add_new_child/3` as code rather than as a value.
    bandit_opts =
      Sourceror.parse_string!(
        "[plug: #{inspect(assigns[:health])}, " <>
          "port: Application.fetch_env!(#{inspect(assigns[:app])}, :health_port)]"
      )

    Igniter.Project.Application.add_new_child(igniter, {Bandit, {:code, bandit_opts}},
      after: after_modules
    )
  end

  defp add_runtime_config(igniter, assigns) do
    app = assigns[:app]

    Gen.append_to_runtime_exs(
      igniter,
      Gen.render_template("worker/runtime_config.exs.eex", assigns),
      Gen.runtime_configures?(app, [:pipeline])
    )
  end

  defp add_notices(igniter, opts, broker) do
    igniter
    |> Igniter.add_notice(Gen.next_steps(:worker, opts))
    |> maybe_add_kafka_notice(broker)
  end

  defp maybe_add_kafka_notice(igniter, :kafka) do
    Igniter.add_notice(
      igniter,
      "broadway_kafka builds brod's crc32cer NIF from source; CMake >= 3.16 must be on PATH"
    )
  end

  defp maybe_add_kafka_notice(igniter, _broker), do: igniter
end
