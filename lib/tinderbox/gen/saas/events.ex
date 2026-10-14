defmodule Tinderbox.Gen.Saas.Events do
  @moduledoc """
  Domain events over NATS JetStream.

  * `<App>.Events` — `publish/3`: a JSON envelope on `<prefix>.<type>`, acknowledged
    by JetStream, never raising,
  * `<App>.Events.StreamBootstrap` — creates the stream and the durable consumer
    when they are missing, retrying forever so a broker outage never stops boot,
  * `<App>.Events.Consumer` + `<App>.Events.Handler` — a `Gnat.Jetstream.PullConsumer`
    that hands each event to the handler, the seam for application code,
  * `<App>.Events.AshNotifier` — publishes every create/update/destroy of the
    resources it is attached to (organizations, memberships, invitations,
    subscriptions),
  * the `:nats` / `:events` runtime config and the three supervisor children.

  Why a pull consumer and not Broadway: the only Broadway/JetStream producer is
  the `jetstream` hex package, last released in 2023 and not part of `gnat`.
  """

  alias Tinderbox.Gen

  @modules [
    {"Events", "events.ex.eex"},
    {"Events.StreamBootstrap", "stream_bootstrap.ex.eex"},
    {"Events.Consumer", "consumer.ex.eex"},
    {"Events.Handler", "handler.ex.eex"},
    {"Events.AshNotifier", "ash_notifier.ex.eex"}
  ]

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    igniter
    |> create_modules(assigns)
    |> add_runtime_config(assigns)
    |> add_children(assigns)
  end

  defp create_modules(igniter, assigns) do
    Gen.create_modules(
      igniter,
      Enum.map(@modules, fn {name, template} ->
        {Module.concat([assigns[:prefix], name]), "saas/events/" <> template}
      end),
      assigns
    )
  end

  defp add_runtime_config(igniter, assigns) do
    Gen.append_to_runtime_exs(
      igniter,
      Gen.render_template("saas/events/runtime_config.exs.eex", assigns),
      Gen.runtime_configures?(assigns[:app], [:nats])
    )
  end

  # Connection, then stream bootstrap, then consumer. Igniter places a child
  # after the *last* module of its `after:` list that it can find, so each child
  # names everything that has to start before it.
  defp add_children(igniter, assigns) do
    app = assigns[:app]
    repo = assigns[:repo]
    bootstrap = Module.concat(assigns[:prefix], "Events.StreamBootstrap")
    consumer = Module.concat(assigns[:prefix], "Events.Consumer")

    # The connection settings come from the runtime config, so they are handed
    # over as code (same technique as the worker stack's health child).
    settings = Sourceror.parse_string!("Application.fetch_env!(#{inspect(app)}, :nats)")

    igniter
    |> Igniter.Project.Application.add_new_child({Gnat.ConnectionSupervisor, {:code, settings}},
      after: [repo]
    )
    |> Igniter.Project.Application.add_new_child(bootstrap,
      after: [repo, Gnat.ConnectionSupervisor]
    )
    |> Igniter.Project.Application.add_new_child(consumer,
      after: [repo, Gnat.ConnectionSupervisor, bootstrap]
    )
  end
end
