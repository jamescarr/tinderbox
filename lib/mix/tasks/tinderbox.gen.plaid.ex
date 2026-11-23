defmodule Mix.Tasks.Tinderbox.Gen.Plaid do
  @shortdoc "Adds the Plaid connector (bank transactions through Plaid Link) to a project generated with --stack saas"

  @moduledoc """
  Adds Plaid to a project generated with `--stack saas` without it (a new project gets
  it with `--plaid`), and integrations and the file drop too when the project has
  none (see `mix tinderbox.gen.integrations`):

  * `<App>.Integrations.Connectors.Plaid`: owners and admins link a bank through Plaid
    Link at `/integrations/plaid`; the `:sync` trigger pulls `/transactions/sync`
    into records of type `account`, `transaction`, `transaction.modified` and
    `transaction.removed` for `<App>.Integrations.Handler`, and Plaid's
    `SYNC_UPDATES_AVAILABLE` webhook (its signature verified) syncs at once,
  * deleting a Plaid source removes its Item at Plaid first; a project whose
    integrations predate this gets `<App>.Integrations.Changes.Disconnect` on the
    source's destroy action and the setup-page check in `Changes.SetupSource`,
  * `PLAID_ENV`, `PLAID_CLIENT_ID`, `PLAID_SECRET` and `PLAID_COUNTRY_CODES` in
    `config/runtime.exs` (production refuses to boot without the keys), the fake
    client the tests use, `plaid_source_fixture/3`, and tests. No migration: Plaid
    adds no table.

  Run it in the project, after adding the tinderbox path dependency back (the
  install notice of `--stack saas` says how), then remove the dependency again:

  ```sh
  mix tinderbox.gen.plaid
  ```

  It leaves `.mise.toml`, `.env.example` and `fly.toml` alone: `PLAID_ENV` defaults
  to `sandbox` and `PLAID_COUNTRY_CODES` to `US`, and the keys go in
  `.mise.local.toml` (production secrets in deployment). It refuses a project that
  is not a `--stack saas` project, one that has Plaid already, one without
  `<App>.Vault` (`mix tinderbox.gen.mfa` creates it), and one whose
  `assets/js/app.js` registers no colocated hooks (phoenix_live_view 1.1).
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _source) do
    %Igniter.Mix.Task.Info{
      group: :tinderbox,
      example: "mix tinderbox.gen.plaid",
      schema: [yes: :boolean]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Tinderbox.Gen.Saas.Plaid.install(igniter, igniter.args.options)
  end
end
