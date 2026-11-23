defmodule Tinderbox.Gen.Saas.Integrations do
  @moduledoc """
  Integrations (`--integrations`, or `mix tinderbox.gen.integrations` on an
  existing SaaS project): a native connector framework, on top of the file drop
  (`Tinderbox.Gen.Saas.FileDrop`, applied first when the project lacks it).

    * `<App>.Integrations` - the Ash domain and facade: the connector catalog
      (`config :<app>, <App>.Integrations, connectors: [...]`), `ingest/2` (every
      record stored once per source, type and external id), `deliver/2`
      (webhooks), `ensure_source/2`,
    * `<App>.Integrations.Connector` - the behaviour of a connector (files,
      webhooks, scheduled pulls), and `.Connectors.Webhook`, the generic JSON one
      n8n, Zapier or Make post to,
    * `<App>.Integrations.Source` (an organization's connector: config, credentials
      encrypted with `<App>.Vault`, a hashed webhook token, the `:sync` trigger) and
      `.Record` (the inbox, whose `:process` trigger hands each record to
      `<App>.Integrations.Handler`, the module the application edits),
    * `<App>.Integrations.DropHandler` - the file drop's handler from now on: a
      dropped file goes to the connector that recognizes it,
    * `<App>Web.Plugs.IntegrationWebhook` (`POST /webhooks/integrations/<source id>`,
      in the endpoint before `Plug.Parsers`) and `<App>Web.IntegrationsLive`
      (`/integrations`), an Integrations entry in the navigation,
      `source_fixture/3` in `<App>.Fixtures`, and tests.

  No workflow engine is deployed: n8n, Zapier and Make stay outside and post to a
  webhook source. Edits to existing files are guarded, so applying twice changes
  nothing; a file drop handler the project has replaced is left alone, with a
  warning.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits
  alias Tinderbox.Gen.Saas.FileDrop

  @platform_nav ~s(<.nav_section :if={@current_user.role == :admin})

  @doc "Expects the file drop to be applied already (`Tinderbox.Gen.Saas.FileDrop.apply/2`)."
  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    {igniter, assigns} = FileDrop.assigns(igniter, assigns)

    igniter
    |> create_modules(assigns)
    |> register_domain(assigns)
    |> add_queue(assigns)
    |> add_config(assigns)
    |> use_drop_handler(assigns)
    |> mount_webhook(assigns)
    |> add_route(assigns)
    |> add_navigation(assigns)
    |> add_fixture(assigns)
    |> add_tests(assigns)
  end

  @doc """
  Adds integrations to a project generated with `--stack saas`, with the file
  drop when it has none: what `mix tinderbox.gen.integrations` runs. Raises when
  the project is not a SaaS project, already has integrations, or has no vault
  to encrypt credentials with.
  """
  @spec install(Igniter.t(), keyword()) :: Igniter.t()
  def install(igniter, opts) do
    {igniter, assigns} = Tinderbox.Gen.Saas.assigns(igniter, opts)
    integrations = Module.concat(assigns[:prefix], "Integrations")
    vault = Module.concat(assigns[:prefix], "Vault")
    file_drop = Module.concat(assigns[:prefix], "FileDrop")

    igniter =
      FileDrop.require_saas!(igniter, assigns, "mix tinderbox.gen.integrations adds integrations")

    {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, integrations)

    if exists? do
      Mix.raise("#{inspect(integrations)} already exists: this project has integrations.")
    end

    {vault?, igniter} = Igniter.Project.Module.module_exists(igniter, vault)

    unless vault? do
      Mix.raise(
        "#{inspect(vault)} is missing: run mix tinderbox.gen.mfa first, it creates the " <>
          "vault that encrypts credentials."
      )
    end

    {file_drop?, igniter} = Igniter.Project.Module.module_exists(igniter, file_drop)

    igniter
    |> then(&if(file_drop?, do: &1, else: FileDrop.apply(&1, assigns)))
    |> __MODULE__.apply(assigns)
    |> Ash.Igniter.codegen("add_integrations")
    # Ash formats the migration once, and `mix format --check-formatted` would
    # fail on the fresh file (see `Tinderbox.Gen.Saas.generate/2`).
    |> Igniter.add_task("format", ["priv/repo/migrations/*add_integrations.exs"])
    |> then(&if(file_drop?, do: &1, else: Igniter.add_notice(&1, FileDrop.notice())))
    |> Igniter.add_notice(
      "Integrations added at /integrations. Run `mix ash.migrate`. Sources take webhook " <>
        "deliveries at POST /webhooks/integrations/<source id>; connectors are listed in " <>
        "`config :#{assigns[:app]}, #{inspect(integrations)}, connectors: [...]`, and records " <>
        "become rows in #{inspect(integrations)}.Handler."
    )
  end

  # -- modules ------------------------------------------------------------------

  defp create_modules(igniter, assigns) do
    integrations = assigns[:integrations]
    web = assigns[:web]

    modules = [
      {integrations, "integrations.ex.eex"},
      {Module.concat(integrations, "Connector"), "connector.ex.eex"},
      {Module.concat(integrations, "Source"), "source.ex.eex"},
      {Module.concat(integrations, "Record"), "record.ex.eex"},
      {Module.concat(integrations, "Handler"), "handler.ex.eex"},
      {Module.concat(integrations, "DropHandler"), "drop_handler.ex.eex"},
      {Module.concat([integrations, "Connectors", "Webhook"]), "connectors/webhook.ex.eex"},
      {Module.concat([integrations, "Changes", "SetupSource"]), "changes/setup_source.ex.eex"},
      {Module.concat([integrations, "Changes", "Sync"]), "changes/sync.ex.eex"},
      {Module.concat([integrations, "Changes", "Process"]), "changes/process.ex.eex"},
      {Module.concat([integrations, "Changes", "Broadcast"]), "changes/broadcast.ex.eex"},
      {Module.concat([integrations, "Changes", "Disconnect"]), "changes/disconnect.ex.eex"},
      {Module.concat([web, "Plugs", "IntegrationWebhook"]), "webhook_plug.ex.eex"},
      {Module.concat(web, "IntegrationsLive"), "integrations_live.ex.eex"}
    ]

    Gen.create_modules(
      igniter,
      Enum.map(modules, fn {module, template} -> {module, "saas/integrations/#{template}"} end),
      assigns
    )
  end

  # -- config -------------------------------------------------------------------

  defp register_domain(igniter, assigns) do
    domain = assigns[:integrations]

    Igniter.Project.Config.configure(
      igniter,
      "config.exs",
      assigns[:app],
      [:ash_domains],
      [domain],
      updater: fn zipper -> Igniter.Code.List.prepend_new_to_list(zipper, domain) end
    )
  end

  # The `:sync` and `:process` triggers run on the `integrations` queue.
  defp add_queue(igniter, assigns) do
    Igniter.Project.Config.configure(
      igniter,
      "config.exs",
      assigns[:app],
      [Oban, :queues],
      [integrations: 5],
      updater: fn zipper ->
        Igniter.Code.Keyword.set_keyword_key(zipper, :integrations, 5, fn queue ->
          {:ok, queue}
        end)
      end
    )
  end

  defp add_config(igniter, assigns) do
    integrations = assigns[:integrations]
    app = assigns[:app]

    igniter
    |> Igniter.Project.Config.configure_new(
      "config.exs",
      app,
      [integrations, :connectors],
      [Module.concat([integrations, "Connectors", "Webhook"])]
    )
    |> Igniter.Project.Config.configure_new(
      "config.exs",
      app,
      [integrations, :webhook_max_bytes],
      5_000_000
    )
  end

  # Dropped files go to the connectors from now on, unless the project has a handler
  # of its own: that one stays, and the warning says how to chain the connectors in.
  defp use_drop_handler(igniter, assigns) do
    file_drop = assigns[:file_drop]
    keep = Module.concat([file_drop, "Handlers", "Keep"])
    drop_handler = Module.concat(assigns[:integrations], "DropHandler")

    igniter =
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        assigns[:app],
        [file_drop, :handler],
        drop_handler,
        updater: fn zipper ->
          if Igniter.Code.Common.nodes_equal?(zipper, keep),
            do: {:ok, Igniter.Code.Common.replace_code(zipper, inspect(drop_handler))},
            else: {:ok, zipper}
        end
      )

    case config_mentions?(igniter, inspect(drop_handler)) do
      {igniter, true} ->
        igniter

      {igniter, false} ->
        Igniter.add_warning(
          igniter,
          "#{inspect(file_drop)} has a handler of its own, so dropped files do not go to " <>
            "the integration connectors. To send them there, call " <>
            "#{inspect(drop_handler)}.handle/2 from that handler (and hints/1 for the page's " <>
            "\"What is this?\" select)."
        )
    end
  end

  defp config_mentions?(igniter, snippet) do
    path = "config/config.exs"

    if Igniter.exists?(igniter, path) do
      igniter = Igniter.include_existing_file(igniter, path)

      content =
        igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)

      {igniter, String.contains?(content, snippet)}
    else
      {igniter, false}
    end
  end

  # Before `Plug.Parsers`, so the connector gets the raw body.
  defp mount_webhook(igniter, assigns) do
    Edits.insert_before_plug(
      igniter,
      assigns[:endpoint],
      Plug.Parsers,
      ~s(plug #{inspect(assigns[:web])}.Plugs.IntegrationWebhook, at: "/webhooks/integrations")
    )
  end

  # -- route and navigation -----------------------------------------------------------

  defp add_route(igniter, assigns) do
    router = assigns[:router]
    route = ~s(live "/integrations", IntegrationsLive)

    Edits.unless_contains(
      igniter,
      router,
      route,
      &Edits.add_to_live_session(&1, router, :authenticated_routes, route)
    )
  end

  @nav_entry ~s(<.nav_item navigate={~p"/integrations"} icon="hero-puzzle-piece" active={@current_page == :integrations}>Integrations</.nav_item>)

  defp add_navigation(igniter, assigns) do
    layouts = Module.concat(assigns[:web], "Layouts")

    Gen.rewrite_module(igniter, layouts, fn content ->
      cond do
        String.contains?(content, ~s(~p"/integrations")) ->
          {:ok, content}

        new = after_files(content) ->
          {:ok, new}

        new = Edits.insert_line(content, @platform_nav, @nav_entry, :before) ->
          {:ok, new}

        true ->
          {:warning,
           "Could not add Integrations to the navigation in #{inspect(layouts)}; add " <>
             "#{@nav_entry} to its nav slot by hand."}
      end
    end)
  end

  # After the Files entry, which the formatter may have broken over several lines:
  # after the first `</.nav_item>` from the line that links `/drop`.
  defp after_files(content) do
    lines = String.split(content, "\n")

    with start when is_integer(start) <-
           Enum.find_index(lines, &String.contains?(&1, ~s(~p"/drop"))),
         offset when is_integer(offset) <-
           lines |> Enum.drop(start) |> Enum.find_index(&String.contains?(&1, "</.nav_item>")) do
      [indent] = Regex.run(~r/^\s*/, Enum.at(lines, start))

      lines |> List.insert_at(start + offset + 1, indent <> @nav_entry) |> Enum.join("\n")
    else
      _missing -> nil
    end
  end

  # -- test support and tests -------------------------------------------------------

  defp add_fixture(igniter, assigns) do
    fixtures = Module.concat(assigns[:prefix], "Fixtures")

    Edits.unless_contains(igniter, fixtures, "def source_fixture(", fn igniter ->
      Edits.append_to_module(igniter, fixtures, render("fixture.ex.eex", assigns))
    end)
  end

  defp add_tests(igniter, assigns) do
    app = assigns[:app]

    [
      {"test/#{app}/integrations_test.exs", "integrations_test.exs.eex"},
      {"test/#{app}_web/integration_webhook_test.exs", "integration_webhook_test.exs.eex"},
      {"test/#{app}_web/live/integrations_live_test.exs", "integrations_live_test.exs.eex"}
    ]
    |> Enum.reduce(igniter, fn {path, template}, igniter ->
      Igniter.create_new_file(igniter, path, render(template, assigns))
    end)
  end

  defp render(template, assigns),
    do: Gen.render_template("saas/integrations/#{template}", assigns)
end
