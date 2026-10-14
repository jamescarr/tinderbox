defmodule Mix.Tasks.Tinderbox.Gen.Mfa do
  @shortdoc "Adds multi-factor authentication to a project generated with --stack saas"

  @moduledoc """
  Adds multi-factor authentication to a project generated with `--stack saas`
  before that stack had it (a new `--stack saas` project has it already):

  * self-hosted TOTP with recovery codes, at `/settings/security`, with the secrets
    encrypted at rest (AshCloak, `<App>.Vault`, keyed by `CLOAK_KEY`),
  * a second step at sign-in (`/mfa`), for password and SSO sign-ins,
  * `/admin/security`: everyone's status, and a reset for people who lost their device,
  * `MFA_REQUIRED=true` to make everyone without a factor set one up at their next
    sign-in, `MFA_SSO=idp` to trust the MFA the SSO provider reports in the ID token,
    and `SSO_ACR_VALUES` to ask it for a step-up (see `config/runtime.exs`),
  * a Security entry in the user menu and a Two-factor entry in the admin navigation,
  * a migration (`*_add_mfa.exs`), and tests for the facade, the controller and the page.

  `<App>Web.AuthController` is replaced when it is still the one
  `ash_authentication_phoenix` generated; a customized one is left alone, with a
  warning saying which calls to add.

  Run it in the project, after adding the tinderbox path dependency back (the
  install notice of `--stack saas` says how), then remove the dependency again:

  ```sh
  mix tinderbox.gen.mfa
  mix ash.migrate
  ```

  It refuses a project that is not a `--stack saas` project, and one that has
  `<App>.Accounts.MFA` already.
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _source) do
    %Igniter.Mix.Task.Info{
      group: :tinderbox,
      example: "mix tinderbox.gen.mfa",
      schema: [yes: :boolean],
      # Run directly, a task's adds_deps is not installed; Mfa.install/2 adds them to mix.exs.
      adds_deps: Tinderbox.Gen.Saas.Mfa.deps()
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Tinderbox.Gen.Saas.Mfa.install(igniter, igniter.args.options)
  end
end
