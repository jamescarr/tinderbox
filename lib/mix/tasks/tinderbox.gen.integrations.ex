defmodule Mix.Tasks.Tinderbox.Gen.Integrations do
  @shortdoc "Adds integrations (connectors, sources, webhooks) to a project generated with --stack saas"

  @moduledoc """
  Adds integrations to a project generated with `--stack saas` without them (a new
  project gets them with `--integrations`), and the file drop too when the project
  has none (see `mix tinderbox.gen.file_drop`):

  * `<App>.Integrations`: a catalog of connectors (`<App>.Integrations.Connector`)
    that turn dropped files, webhook deliveries or scheduled pulls into records,
    each stored once and handed, with retries, to `<App>.Integrations.Handler`,
    where the application turns them into its own rows,
  * sources per organization, with encrypted credentials and a webhook token, at
    `/integrations`; `POST /webhooks/integrations/<source id>` for n8n, Zapier,
    Make or a script (the generic `webhook` connector),
  * the file drop's handler becomes `<App>.Integrations.DropHandler`, unless the
    project has its own (a warning then says how to chain it),
  * a migration (`*_add_integrations.exs`), `source_fixture/3`, and tests.

  Run it in the project, after adding the tinderbox path dependency back (the
  install notice of `--stack saas` says how), then remove the dependency again:

  ```sh
  mix tinderbox.gen.integrations
  mix ash.migrate
  ```

  It refuses a project that is not a `--stack saas` project, one that has
  `<App>.Integrations` already, and one without `<App>.Vault`
  (`mix tinderbox.gen.mfa` creates it).
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _source) do
    %Igniter.Mix.Task.Info{
      group: :tinderbox,
      example: "mix tinderbox.gen.integrations",
      schema: [yes: :boolean]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Tinderbox.Gen.Saas.Integrations.install(igniter, igniter.args.options)
  end
end
