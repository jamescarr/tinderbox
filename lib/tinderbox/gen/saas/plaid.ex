defmodule Tinderbox.Gen.Saas.Plaid do
  @moduledoc """
  Plaid (`--plaid`, or `mix tinderbox.gen.plaid` on an existing SaaS project): a
  connector of the integrations block (`Tinderbox.Gen.Saas.Integrations`, applied
  first when the project lacks it) that links banks through Plaid Link and pulls
  their transactions.

    * `<App>.Integrations.Connectors.Plaid` - the connector: `connect/4` (Link's
      public token for an access token, kept in the source's encrypted
      credentials), `sync/1` (`/transactions/sync` from the source's cursor, on the
      15-minute `:sync` trigger), `disconnect/1` (`/item/remove` before the source
      is deleted) and `handle_webhook/2` (Plaid's `SYNC_UPDATES_AVAILABLE` asks for
      a sync at once),
    * `.Client` (`post/2`), `.Client.HTTP` (Req, against `PLAID_ENV`'s host),
      `.Client.Fake` (what the tests talk to), `.Error`, and `.Webhook` (Plaid's
      ES256 webhook signature, with its keys cached in `:persistent_term`),
    * `<App>Web.PlaidLive` (`/integrations/plaid`, owners and admins), linked from
      `/integrations`; Plaid in the connector catalog after the webhook connector;
      its settings in `runtime.exs` (production refuses to boot without
      `PLAID_CLIENT_ID` and `PLAID_SECRET`); `plaid_source_fixture/3` in
      `<App>.Fixtures`, and tests.

  Plaid adds no table. A project whose integrations predate connector setup pages
  is brought up to date: `Connector` gains the `setup_path/0` and `disconnect/1`
  callbacks, the source's destroy action gains
  `<App>.Integrations.Changes.Disconnect`, `Changes.SetupSource` refuses a Plaid
  source without credentials, and `deliver/2` leaves a source alone when a webhook
  delivers no records. Edits are guarded, so applying twice changes nothing.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits
  alias Tinderbox.Gen.Saas.FileDrop
  alias Tinderbox.Gen.Saas.Integrations

  # `require_setup/2` of `priv/templates/saas/integrations/changes/setup_source.ex.eex`,
  # for a `SetupSource` generated before it.
  @require_setup """

    # A connector set up on its own page (Plaid Link) needs the credentials that page obtains;
    # the generic form never sends any. AshCloak turns `credentials` into an action argument
    # (its `Encrypt` change reads it with `fetch_argument/2` in a before_action), so that is
    # where a provided value is at this point.
    defp require_setup(changeset, connector) do
      provided? =
        match?(
          {:ok, %{} = credentials} when map_size(credentials) > 0,
          Ash.Changeset.fetch_argument(changeset, :credentials)
        )

      if Integrations.exports?(connector, :setup_path, 0) and not provided? do
        Ash.Changeset.add_error(changeset,
          field: :connector,
          message: "is set up at \#{connector.setup_path()}"
        )
      else
        changeset
      end
    end
  """

  @quiet_delivery "{:ok, []} -> {:ok, %{created: 0, duplicates: 0}}"

  # The callbacks of `priv/templates/saas/integrations/connector.ex.eex` that Plaid
  # implements, for a `Connector` generated before them. `@optional_callbacks`
  # accumulates, so the behaviour's own list is left as it is.
  @setup_callbacks """
  @doc "Where a source of this connector is set up when the generic form cannot (see the module doc)."
  @callback setup_path() :: String.t()

  @doc "Revokes what the connector holds elsewhere for `source` (its credentials are loaded) before the source is deleted."
  @callback disconnect(source :: map()) :: :ok | {:error, term()}

  @optional_callbacks setup_path: 0, disconnect: 1
  """

  @doc "Expects integrations to be applied already (`Tinderbox.Gen.Saas.Integrations.apply/2`)."
  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    {igniter, assigns} = FileDrop.assigns(igniter, assigns)

    assigns =
      Keyword.put(assigns, :plaid, Module.concat([assigns[:integrations], "Connectors", "Plaid"]))

    igniter
    |> create_modules(assigns)
    |> add_connector(assigns)
    |> add_runtime_config(assigns)
    |> add_route(assigns)
    |> ensure_connector_callbacks(assigns)
    |> ensure_disconnect(assigns)
    |> ensure_setup_guard(assigns)
    |> ensure_quiet_delivery(assigns)
    |> check_integrations_live(assigns)
    |> check_sync_cursor(assigns)
    |> add_fixture(assigns)
    |> add_tests(assigns)
  end

  @doc """
  Adds Plaid to a project generated with `--stack saas`, with integrations (and the
  file drop) when it has none: what `mix tinderbox.gen.plaid` runs. Raises when the
  project is not a SaaS project, already has Plaid, has no vault to encrypt
  credentials with, or registers no colocated hooks in `assets/js/app.js`.
  """
  @spec install(Igniter.t(), keyword()) :: Igniter.t()
  def install(igniter, opts) do
    {igniter, assigns} = Tinderbox.Gen.Saas.assigns(igniter, opts)
    integrations = Module.concat(assigns[:prefix], "Integrations")
    plaid = Module.concat([integrations, "Connectors", "Plaid"])

    igniter = FileDrop.require_saas!(igniter, assigns, "mix tinderbox.gen.plaid adds Plaid")

    {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, plaid)

    if exists? do
      Mix.raise("#{inspect(plaid)} already exists: this project has Plaid.")
    end

    igniter = require_colocated_hooks!(igniter)
    {integrations?, igniter} = Igniter.Project.Module.module_exists(igniter, integrations)

    igniter
    |> then(&if(integrations?, do: &1, else: Integrations.install(&1, opts)))
    |> __MODULE__.apply(assigns)
    |> Igniter.add_notice(notice(assigns))
  end

  @doc false
  @spec notice(keyword()) :: String.t()
  def notice(assigns) do
    integrations = Module.concat(assigns[:prefix], "Integrations")

    "Plaid added at /integrations/plaid. Put PLAID_CLIENT_ID and PLAID_SECRET (sandbox " <>
      "keys, https://dashboard.plaid.com/developers/keys) in .mise.local.toml; production " <>
      "refuses to boot without them. Plaid's SYNC_UPDATES_AVAILABLE webhook is registered " <>
      "per linked bank at POST /webhooks/integrations/<source id>; records of type account, " <>
      "transaction, transaction.modified and transaction.removed reach " <>
      "#{inspect(integrations)}.Handler."
  end

  # Plaid Link's hook is a colocated one (phoenix_live_view 1.1); app.js has to register them.
  defp require_colocated_hooks!(igniter) do
    path = "assets/js/app.js"

    if Igniter.exists?(igniter, path) do
      igniter = Igniter.include_existing_file(igniter, path)
      content = igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)

      unless String.contains?(content, "colocatedHooks") do
        Mix.raise(
          "assets/js/app.js does not register colocated hooks (phoenix_live_view 1.1): " <>
            "Plaid Link's hook needs them; upgrade first."
        )
      end

      igniter
    else
      igniter
    end
  end

  # -- modules ------------------------------------------------------------------

  defp create_modules(igniter, assigns) do
    plaid = assigns[:plaid]

    modules = [
      {plaid, "connectors/plaid.ex.eex"},
      {Module.concat(plaid, "Error"), "connectors/plaid/error.ex.eex"},
      {Module.concat(plaid, "Client"), "connectors/plaid/client.ex.eex"},
      {Module.concat([plaid, "Client", "HTTP"]), "connectors/plaid/client/http.ex.eex"},
      {Module.concat([plaid, "Client", "Fake"]), "connectors/plaid/client/fake.ex.eex"},
      {Module.concat(plaid, "Webhook"), "connectors/plaid/webhook.ex.eex"},
      {Module.concat(assigns[:web], "PlaidLive"), "plaid_live.ex.eex"}
    ]

    Gen.create_modules(
      igniter,
      Enum.map(modules, fn {module, template} -> {module, "saas/plaid/#{template}"} end),
      assigns
    )
  end

  # -- config -------------------------------------------------------------------

  # After the generic webhook connector, which `Integrations` lists first.
  defp add_connector(igniter, assigns) do
    integrations = assigns[:integrations]
    plaid = assigns[:plaid]
    webhook = Module.concat([integrations, "Connectors", "Webhook"])

    Igniter.Project.Config.configure(
      igniter,
      "config.exs",
      assigns[:app],
      [integrations, :connectors],
      [webhook, plaid],
      updater: &Igniter.Code.List.append_new_to_list(&1, plaid)
    )
  end

  defp add_runtime_config(igniter, assigns) do
    Gen.append_to_runtime_exs(
      igniter,
      render("runtime_config.exs.eex", assigns),
      Gen.runtime_contains?("PLAID_CLIENT_ID")
    )
  end

  # -- route --------------------------------------------------------------------------

  # No navigation entry: `/integrations` links to it.
  defp add_route(igniter, assigns) do
    router = assigns[:router]
    route = ~s(live "/integrations/plaid", PlaidLive)

    Edits.unless_contains(
      igniter,
      router,
      route,
      &Edits.add_to_live_session(&1, router, :authenticated_routes, route)
    )
  end

  # -- integrations generated before connector setup pages ------------------------------

  # Plaid implements `setup_path/0` and `disconnect/1` with `@impl true`, which warns
  # (and fails `--warnings-as-errors`) unless the behaviour declares them.
  defp ensure_connector_callbacks(igniter, assigns) do
    connector = Module.concat(assigns[:integrations], "Connector")

    Edits.unless_contains(igniter, connector, "@callback setup_path()", fn igniter ->
      Gen.rewrite_module(igniter, connector, fn content ->
        case Edits.insert_line(content, "@optional_callbacks", @setup_callbacks, :before) do
          nil ->
            {:warning,
             "Could not add setup_path/0 and disconnect/1 to #{inspect(connector)}: " <>
               "#{inspect(assigns[:plaid])} implements them with @impl true, so compiling " <>
               "warns. Copy the two callbacks from tinderbox's connector.ex.eex."}

          new ->
            {:ok, new}
        end
      end)
    end)
  end

  defp ensure_disconnect(igniter, assigns) do
    integrations = assigns[:integrations]
    disconnect = Module.concat([integrations, "Changes", "Disconnect"])
    source = Module.concat(integrations, "Source")
    change = "change #{inspect(disconnect)}"

    igniter =
      case Igniter.Project.Module.module_exists(igniter, disconnect) do
        {true, igniter} ->
          igniter

        {false, igniter} ->
          Gen.create_modules(
            igniter,
            [{disconnect, "saas/integrations/changes/disconnect.ex.eex"}],
            assigns
          )
      end

    Edits.unless_contains(igniter, source, "Changes.Disconnect", fn igniter ->
      Gen.rewrite_module(igniter, source, fn content ->
        case Edits.insert_line(content, "destroy :destroy do", "  " <> change, :after) do
          nil ->
            {:warning,
             "Could not add #{inspect(disconnect)} to #{inspect(source)}'s destroy action; " <>
               "add `#{change}` to it by hand, else deleting a Plaid source leaves its " <>
               "Item (and its billing) at Plaid."}

          new ->
            {:ok, new}
        end
      end)
    end)
  end

  defp ensure_setup_guard(igniter, assigns) do
    setup_source = Module.concat([assigns[:integrations], "Changes", "SetupSource"])

    Edits.unless_contains(igniter, setup_source, "require_setup", fn igniter ->
      Gen.rewrite_module(igniter, setup_source, fn content ->
        with piped when is_binary(piped) <-
               Edits.insert_line(
                 content,
                 "|> default_name(connector)",
                 "|> require_setup(connector)",
                 :after
               ),
             trimmed = String.trim_trailing(piped),
             true <- String.ends_with?(trimmed, "end") do
          {:ok, String.replace_suffix(trimmed, "end", @require_setup <> "end\n")}
        else
          _missing ->
            {:warning,
             "Could not add the setup-page check to #{inspect(setup_source)}: a Plaid " <>
               "source added through the form on /integrations has no bank behind it and " <>
               "ends in error; copy require_setup/2 from tinderbox's setup_source.ex.eex."}
        end
      end)
    end)
  end

  # Plaid's webhook only asks for a sync; `ingest/2` of no records would mark the
  # source synced just now, and the `:sync` trigger would skip it.
  defp ensure_quiet_delivery(igniter, assigns) do
    integrations = assigns[:integrations]

    Edits.unless_contains(igniter, integrations, @quiet_delivery, fn igniter ->
      Gen.rewrite_module(igniter, integrations, fn content ->
        case Edits.insert_line(
               content,
               "{:ok, records} -> ingest(source, records)",
               @quiet_delivery,
               :before
             ) do
          nil ->
            {:warning,
             "Could not make #{inspect(integrations)}.deliver/2 skip deliveries without " <>
               "records: Plaid's webhook cannot hurry a sync, and its banks sync on the " <>
               "15-minute schedule. Add `#{@quiet_delivery}` before the clause that calls " <>
               "ingest/2."}

          new ->
            {:ok, new}
        end
      end)
    end)
  end

  defp check_integrations_live(igniter, assigns) do
    live = Module.concat(assigns[:web], "IntegrationsLive")

    case Edits.source_contains?(igniter, live, "setup_path") do
      {igniter, true} ->
        igniter

      {igniter, false} ->
        Igniter.add_warning(
          igniter,
          "#{inspect(live)} predates connector setup pages: its Add-a-source form still " <>
            "lists Plaid (such a source is refused). To hide it and link /integrations/plaid " <>
            "instead, copy the @addable handling from tinderbox's integrations_live.ex.eex."
        )
    end
  end

  # Plaid numbers its records from the `seq` stored with the cursor: a Sync change that
  # stores the cursor after the records lets a sync retried in between number again.
  defp check_sync_cursor(igniter, assigns) do
    sync = Module.concat([assigns[:integrations], "Changes", "Sync"])

    case Edits.source_contains?(igniter, sync, "ingest(source, records, cursor)") do
      {igniter, true} ->
        igniter

      {igniter, false} ->
        Igniter.add_warning(
          igniter,
          "#{inspect(sync)} stores the cursor after the records: a sync retried in " <>
            "between numbers Plaid's records from the old seq again, so a handler can " <>
            "drop a newer revision. To store both in one transaction, copy ingest/3 " <>
            "from tinderbox's integrations.ex.eex and its call from changes/sync.ex.eex."
        )
    end
  end

  # -- test support and tests -------------------------------------------------------

  defp add_fixture(igniter, assigns) do
    fixtures = Module.concat(assigns[:prefix], "Fixtures")

    Edits.unless_contains(igniter, fixtures, "def plaid_source_fixture(", fn igniter ->
      Edits.append_to_module(igniter, fixtures, render("fixture.ex.eex", assigns))
    end)
  end

  defp add_tests(igniter, assigns) do
    app = assigns[:app]

    [
      {"test/#{app}/integrations/plaid_test.exs", "plaid_test.exs.eex"},
      {"test/#{app}_web/live/plaid_live_test.exs", "plaid_live_test.exs.eex"}
    ]
    |> Enum.reduce(igniter, fn {path, template}, igniter ->
      Igniter.create_new_file(igniter, path, render(template, assigns))
    end)
  end

  defp render(template, assigns), do: Gen.render_template("saas/plaid/#{template}", assigns)
end
