defmodule Tinderbox.Gen.Saas do
  @moduledoc """
  Generates the SaaS stack on top of a Phoenix project: sign-in with password and
  generic OIDC (SSO), organizations with memberships and invitations, Stripe
  subscriptions, an in-house notification platform behind a Knock-shaped facade,
  NATS JetStream events, an admin section, all on the themepack UI kit, and the
  operational pieces (health, metrics, tracing, mail, release, CI).

  Igniter installs the Ash/AshAuthentication/Oban packages and runs their
  installers *before* this module runs (they are declared in
  `Mix.Tasks.Tinderbox.Gen.Saas.info/2`), so `<App>.Repo`, `<App>.Accounts`,
  `<App>.Accounts.User`, `<App>.Accounts.Token`, `<App>.Secrets`, the router with
  its authentication routes, `<App>Web.LiveUserAuth` and the Oban child already
  exist. Each concern below is its own module, applied in this order, and takes
  the shared `t:assigns/0`:

  | Module | Concern |
  |---|---|
  | `Tinderbox.Gen.Ui` | themepack + UI kit (`--themepack`) |
  | `Tinderbox.Gen.Storage` | object storage wiring both stacks share |
  | `#{inspect(__MODULE__)}.Accounts` | sign-in strategies, roles, organizations, memberships, invitations |
  | `#{inspect(__MODULE__)}.Web` | layout, landing page, LiveViews, routes |
  | `#{inspect(__MODULE__)}.Concept` | `<App>.Concept` (the landing page's copy and pricing, the activation event, the thresholds) and the starter `concept.exs` |
  | `#{inspect(__MODULE__)}.Billing` | Stripe plans, subscriptions, webhooks, AshOban sync |
  | `#{inspect(__MODULE__)}.Notifications` | notification facade, Local adapter, inbox, preferences, email |
  | `#{inspect(__MODULE__)}.Events` | JetStream publisher, stream bootstrap, consumer, Ash notifier |
  | `#{inspect(__MODULE__)}.Api` | AshJsonApi mount for the accounts domain |
  | `#{inspect(__MODULE__)}.Connections` | OAuth2 client credentials per organization: provider behaviour (Hydra, Auth0), token verification, the API plug |
  | `#{inspect(__MODULE__)}.Admin` | `/admin` (UI kit) and `/admin/flags` (FunWithFlags) |
  | `#{inspect(__MODULE__)}.Validation` | first-party analytics, the waitlist, `/admin/validation` (the funnel against the thresholds) and `/admin/waitlist` |
  | `#{inspect(__MODULE__)}.Mfa` | two-factor authentication (TOTP, or the SSO provider's MFA), `/settings/security`, `/admin/security` |
  | `#{inspect(__MODULE__)}.Ops` | health, PromEx, OpenTelemetry, mail, release, CI |
  | `#{inspect(__MODULE__)}.Generators` | the project's own generators: `mix <app>.gen.domain`, `.gen.resource`, `.gen.live`, `.gen.concept` |
  | `#{inspect(__MODULE__)}.Deploy` | Fly.io (`--deploy fly`, the default): `fly.toml`, the NATS app, `mise run deploy` |

  Edits to files the Phoenix and Ash installers created are guarded so that
  re-running the generator leaves them alone (see
  `Tinderbox.Gen.Saas.Edits`).
  """

  alias Tinderbox.Broker
  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Accounts
  alias Tinderbox.Gen.Saas.Admin
  alias Tinderbox.Gen.Saas.Api
  alias Tinderbox.Gen.Saas.Billing
  alias Tinderbox.Gen.Saas.Concept
  alias Tinderbox.Gen.Saas.Connections
  alias Tinderbox.Gen.Saas.Deploy
  alias Tinderbox.Gen.Saas.Events
  alias Tinderbox.Gen.Saas.Flags
  alias Tinderbox.Gen.Saas.Generators
  alias Tinderbox.Gen.Saas.Mfa
  alias Tinderbox.Gen.Saas.Notifications
  alias Tinderbox.Gen.Saas.Ops
  alias Tinderbox.Gen.Saas.Validation
  alias Tinderbox.Gen.Saas.Web
  alias Tinderbox.Gen.Storage

  @typedoc """
  What every sub-step is given: the OTP app, its names, and the modules the
  installers created. Templates reach sibling modules as
  `<%= inspect(@prefix) %>.Name`.

    * `:app` / `:app_dash` - OTP app name, and the same with `_` as `-`
    * `:prefix` - base module, e.g. `MyApp`
    * `:web` - web module, e.g. `MyAppWeb`
    * `:accounts` / `:user` / `:token` - `MyApp.Accounts`, `.User`, `.Token`
    * `:connections` / `:connection` / `:provider` - `MyApp.Connections`, `.Connection`,
      `.Provider`: the API connections, which the web layer and the tests refer to
    * `:secrets` - `MyApp.Secrets`
    * `:repo`, `:endpoint`, `:router`, `:mailer`, `:pubsub`
    * `:opts` - the task's options
  """
  @type assigns :: keyword()

  @spec apply(Igniter.t(), Keyword.t()) :: Igniter.t()
  def apply(igniter, opts) do
    require_phoenix!(igniter)
    {igniter, assigns} = assigns(igniter, opts)

    igniter
    |> Storage.apply(opts)
    |> generate(assigns)
  end

  # Everything after the shared object storage wiring, in the order the module
  # doc lists it. Separate from `apply/2` so the concerns can be run against a
  # project whose storage is already generated.
  @doc false
  @spec generate(Igniter.t(), assigns()) :: Igniter.t()
  def generate(igniter, assigns) do
    igniter
    |> Tinderbox.Gen.Ui.install_kit(assigns[:opts])
    |> Accounts.apply(assigns)
    |> Web.apply(assigns)
    |> Concept.apply(assigns)
    |> Billing.apply(assigns)
    |> Notifications.apply(assigns)
    |> Events.apply(assigns)
    |> Api.apply(assigns)
    |> Connections.apply(assigns)
    |> Flags.apply(assigns)
    |> Admin.apply(assigns)
    |> Validation.apply(assigns)
    |> Mfa.apply(assigns)
    |> Ops.apply(assigns)
    |> Generators.apply(assigns)
    |> Deploy.apply(assigns)
    # One migration for everything above, named after what was generated.
    |> Ash.Igniter.codegen("add_saas_resources")
    # Ash formats the migration once, and a second pass changes it again
    # (`references(…), null: false`): `mix format --check-formatted`, which CI
    # runs, would fail on the fresh file. Only that migration is touched.
    |> Igniter.add_task("format", ["priv/repo/migrations/*add_saas_resources.exs"])
    |> Igniter.add_notice(Gen.next_steps(:saas, assigns[:opts], assigns[:app]))
  end

  @doc """
  The assigns every sub-step is rendered with. Selects the Phoenix router (the
  project has exactly one), so the igniter is returned too.
  """
  @spec assigns(Igniter.t(), Keyword.t()) :: {Igniter.t(), assigns()}
  def assigns(igniter, opts) do
    app = Igniter.Project.Application.app_name(igniter)
    prefix = Igniter.Project.Module.module_name_prefix(igniter)
    web = Igniter.Libs.Phoenix.web_module(igniter)
    {igniter, router} = Igniter.Libs.Phoenix.select_router(igniter)
    # Strings, not aliases: `Accounts` below is this package's own module.
    accounts = Module.concat(prefix, "Accounts")
    connections = Module.concat(prefix, "Connections")

    {igniter,
     [
       app: app,
       app_dash: Broker.app_dash(app),
       prefix: prefix,
       web: web,
       accounts: accounts,
       user: Module.concat(accounts, "User"),
       connections: connections,
       connection: Module.concat(connections, "Connection"),
       provider: Module.concat(connections, "Provider"),
       token: Module.concat(accounts, "Token"),
       secrets: Module.concat(prefix, "Secrets"),
       repo: Module.concat(prefix, "Repo"),
       endpoint: Igniter.Libs.Phoenix.web_module_name(igniter, "Endpoint"),
       router: router,
       mailer: Module.concat(prefix, "Mailer"),
       pubsub: Module.concat(prefix, "PubSub"),
       opts: opts
     ]}
  end

  defp require_phoenix!(igniter) do
    case Igniter.Libs.Phoenix.list_routers(igniter) do
      {_igniter, []} ->
        Mix.raise("""
        The SaaS stack requires a Phoenix project. Generate it with:

            mix igniter.new my_app --with phx.new \\
              --install tinderbox@path:#{Gen.package_path()} \\
              --stack saas
        """)

      {_igniter, _routers} ->
        igniter
    end
  end
end
