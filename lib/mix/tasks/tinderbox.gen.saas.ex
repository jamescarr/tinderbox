defmodule Mix.Tasks.Tinderbox.Gen.Saas do
  @shortdoc "Generates the SaaS stack (Phoenix + Ash auth/SSO, organizations, billing, admin)"

  @moduledoc """
  Generates a multi-tenant B2B SaaS skeleton in an existing Phoenix project:

  * AshAuthentication with password and generic OIDC (`sso`) sign-in; Dex runs in
    docker compose as the local OIDC provider,
  * organizations, memberships and invitations (Ash policies, AshPaperTrail),
  * multi-factor authentication: TOTP with recovery codes at `/settings/security`
    (secrets encrypted with AshCloak), an admin reset at `/admin/security`,
    `MFA_REQUIRED` to enforce it and `MFA_SSO=idp` to trust the SSO provider's MFA
    (`mix tinderbox.gen.mfa` adds it to a project generated without it),
  * Stripe subscriptions (Checkout, Billing Portal, webhooks, AshOban sync),
  * an in-house notification platform (inbox, per-key channel rules, email)
    behind an adapter facade shaped like Knock,
  * a themepack UI kit (`--themepack ember|slate|harbor`, see `mix tinderbox.gen.ui`),
    an admin section at `/admin`, FunWithFlags at `/admin/flags`,
  * AshJsonApi + OpenAPI, NATS JetStream events, Oban, Swoosh + Mailpit,
    `/health`, OpenTelemetry, PromEx, a release Dockerfile and GitHub Actions CI.

  The Ash packages are fetched and their installers are run by igniter, so this
  task must be run through `mix igniter.install`/`mix igniter.new`:

  ```sh
  mix igniter.new my_app --with phx.new \\
    --install tinderbox@path:/Users/jamescarr/projects/upmarkethq/tinderbox \\
    --stack saas
  ```
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _source) do
    %Igniter.Mix.Task.Info{
      group: :tinderbox,
      example: "mix tinderbox.gen.saas",
      schema: [
        yes: :boolean,
        compose: :boolean,
        mise: :boolean,
        auth_strategy: :csv,
        themepack: :string
      ],
      defaults: [compose: true, mise: true],
      composes: [
        "ash.install",
        "ash_postgres.install",
        "ash_json_api.install",
        "ash_authentication.install",
        "ash_authentication_phoenix.install",
        "oban.install",
        "ash_oban.install",
        "ash_authentication.add_strategy"
      ],
      # The order matters: igniter runs each package's installer with the
      # top-level argv in list order, and `ash_authentication_phoenix.install`
      # expects `<App>.Accounts.User` (created by `ash_authentication.install`)
      # to exist already.
      installs: [
        {:ash, "~> 3.34"},
        {:ash_postgres, "~> 2.14"},
        {:ash_json_api, "~> 1.7"},
        {:ash_phoenix, "~> 2.3"},
        {:ash_authentication, "~> 4.15"},
        {:ash_authentication_phoenix, "~> 2.17"},
        {:oban, "~> 2.24"},
        {:ash_oban, "~> 0.9"},
        {:ash_paper_trail, "~> 0.8"}
      ],
      adds_deps:
        [
          {:gnat, "~> 1.18"},
          {:stripity_stripe, "~> 3.3"},
          {:slugify, "~> 1.3"},
          # Not started by their own applications: `FunWithFlags.Supervisor` starts in
          # the app's tree, after PubSub (see `Tinderbox.Gen.Saas.Flags`).
          {:fun_with_flags, "~> 1.13", runtime: false},
          {:fun_with_flags_ui, "~> 1.1", runtime: false},
          {:prom_ex, "~> 1.12"},
          {:opentelemetry, "~> 1.7"},
          {:opentelemetry_api, "~> 1.5"},
          {:opentelemetry_exporter, "~> 1.11"},
          {:opentelemetry_phoenix, "~> 2.0"},
          {:opentelemetry_bandit, "~> 0.3"},
          {:opentelemetry_ecto, "~> 1.2"},
          {:opentelemetry_oban, "~> 1.2"},
          {:gen_smtp, "~> 1.3"},
          # The password strategy installer adds exactly this requirement itself; a
          # different one would make it stop and ask whether to replace it.
          {:bcrypt_elixir, "~> 3.0"}
        ] ++ Tinderbox.Gen.Saas.Mfa.deps()
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Tinderbox.Gen.Saas.apply(igniter, igniter.args.options)
  end
end
