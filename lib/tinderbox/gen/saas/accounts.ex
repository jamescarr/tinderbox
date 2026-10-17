defmodule Tinderbox.Gen.Saas.Accounts do
  @moduledoc """
  Accounts for the SaaS stack: how people sign in, who they are, and which
  organizations they belong to.

  `ash_authentication.install` already created `<App>.Accounts`, `.User`,
  `.Token` and `<App>.Secrets`, and `ash_authentication_phoenix.install` the
  routes and `<App>Web.LiveUserAuth`. This module adds, on top of them:

  * the password strategy (`ash_authentication.add_strategy password`), which
    brings `email`, `hashed_password`, `confirmed_at` and email confirmation,
  * a `role` (`:member` | `:admin`) on the user, assigned from `ADMIN_EMAILS`
    when someone registers, and a `set_role` action for admins,
  * generic OIDC single sign-on as the `:sso` strategy, with the identity
    resource, the register action, the secrets and the runtime config it needs,
  * the user's read policies (yourself, admins, people in your organizations),
  * the `Organization`, `Membership` and `Invitation` resources with their
    changes, validations and policy check, registered in the accounts domain
    together with AshPaperTrail and AshJsonApi,
  * the building blocks every organization-scoped resource of the application
    reuses: `Changes.InheritOrganization` (copy the organization from a parent),
    `Validations.SameOrganization` (reject ids of another organization's records)
    and `Changes.NotifyManagers` (notify an organization's managers after commit),
  * `<App>.Accounts.managers/1`, an organization's owners and admins (the
    recipients of what happens to it),
  * the organization switcher (`<App>Web.OrganizationController`) and the
    `<App>Web.LiveOrganization` hooks,
  * removal of the `magic_sign_in_route` the Phoenix installer adds, which does
    not compile without a magic-link strategy.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits

  # `ash_authentication` is an optional dependency: the API and worker stacks never
  # load this module, but compiling it as part of tinderbox must stay quiet in a
  # project that does not have the package.
  @compile {:no_warn_undefined, AshAuthentication.Igniter}

  @resources ~w(Organization Membership Invitation)a

  @changes ~w(SetSlug AddOwnerMembership NotifyInvitee AcceptInvitation AssignRole InheritOrganization NotifyManagers)a

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    accounts = assigns[:accounts]

    assigns =
      Keyword.merge(assigns,
        user_identity: Module.concat(accounts, UserIdentity),
        assign_role: Module.concat([accounts, Changes, AssignRole])
      )

    igniter
    |> add_password_strategy(assigns)
    # `ash_authentication.install` ran without a strategy and said so; one is now added.
    |> Edits.drop_notices("add at least one authentication strategy")
    |> configure_user(assigns)
    |> add_sso(assigns)
    |> add_admin_role(assigns)
    |> add_user_policies(assigns)
    |> add_resources(assigns)
    |> configure_domain(assigns)
    |> add_managers(assigns)
    |> remove_magic_link_route(assigns)
    |> add_organization_web(assigns)
    # Without it Ash logs a warning for every `after_transaction` hook that runs
    # inside the test sandbox's transaction.
    |> Igniter.Project.Config.configure("test.exs", :ash, [:warn_on_transaction_hooks?], false)
  end

  # `ash_authentication_phoenix.install` only adds the password strategy when the
  # top-level argv carries `--auth-strategy password`, which nobody types.
  defp add_password_strategy(igniter, assigns) do
    {igniter, defined?} =
      AshAuthentication.Igniter.defines_strategy_of_type(igniter, assigns[:user], :password)

    if defined? do
      igniter
    else
      Igniter.compose_task(igniter, "ash_authentication.add_strategy", ["password"])
    end
  end

  defp configure_user(igniter, assigns) do
    user = assigns[:user]

    igniter
    # The admin user list shows when people registered.
    |> Ash.Resource.Igniter.ensure_timestamps(user)
    |> Ash.Resource.Igniter.add_new_attribute(user, :role, """
    attribute :role, :atom do
      constraints one_of: [:member, :admin]
      default :member
      allow_nil? false
      public? true
    end
    """)
    # An SSO-only user has no password, so `hashed_password` has to accept nil.
    |> Edits.make_attribute_nullable(user, :hashed_password)
    |> Ash.Resource.Igniter.add_new_relationship(
      user,
      :memberships,
      "has_many :memberships, #{inspect(Module.concat(assigns[:accounts], Membership))}"
    )
  end

  defp add_sso(igniter, assigns) do
    user = assigns[:user]
    secrets = assigns[:secrets]

    igniter
    |> AshAuthentication.Igniter.ensure_user_identity_resource(user, assigns[:user_identity])
    |> drop_default_read(assigns[:user_identity])
    |> Ash.Domain.Igniter.add_resource_reference(assigns[:accounts], assigns[:user_identity])
    |> Ash.Resource.Igniter.add_new_action(
      user,
      :register_with_sso,
      Gen.render_template("saas/accounts/user/register_with_sso.eex", assigns)
    )
    |> add_sso_secrets(secrets, user)
    |> AshAuthentication.Igniter.add_new_strategy(
      user,
      :oidc,
      :sso,
      Gen.render_template("saas/accounts/user/sso_strategy.eex", assigns)
    )
    # The identity provider vouches for the address, so no "confirm your email"
    # message is sent to someone who just signed in with it.
    |> Edits.append_to_option_list(
      user,
      [:authentication, :add_ons, :confirmation],
      :auto_confirm_actions,
      :register_with_sso
    )
    |> Gen.append_to_runtime_exs(
      Gen.render_template("saas/accounts/runtime_config.exs.eex", assigns),
      Gen.runtime_configures?(assigns[:app], [:sso_client_id])
    )
  end

  # The identity extension builds the resource's primary read action itself. Since
  # ash 3.36 the `actions do defaults [:read] end` ash_authentication's installer
  # writes next to it is a second `read`, and the resource no longer compiles
  # ("Multiple actions (2) with the name `read` defined").
  defp drop_default_read(igniter, user_identity) do
    Edits.remove_call(igniter, user_identity, :actions, [1], fn candidate ->
      candidate.node |> Sourceror.to_string() |> String.replace(~r/[\s()]+/, "") ==
        "actionsdodefaults[:read]end"
    end)
  end

  defp add_sso_secrets(igniter, secrets, user) do
    [
      client_id: :sso_client_id,
      client_secret: :sso_client_secret,
      redirect_uri: :sso_redirect_uri,
      base_url: :sso_base_url
    ]
    |> Enum.reduce(igniter, fn {option, env_key}, igniter ->
      Edits.ensure_secret_from_env(
        igniter,
        secrets,
        user,
        [:authentication, :strategies, :sso, option],
        env_key
      )
    end)
  end

  defp add_admin_role(igniter, assigns) do
    user = assigns[:user]
    assign_role = assigns[:assign_role]

    igniter
    |> Igniter.Project.Module.create_module(
      assign_role,
      Gen.render_template("saas/accounts/changes/assign_role.ex.eex", assigns)
    )
    |> Ash.Resource.Igniter.add_new_action(user, :set_role, """
    update :set_role do
      description "Changes a user's platform role. Admins only."
      accept [:role]
    end
    """)
    |> Edits.unless_contains(
      user,
      inspect(assign_role),
      &Ash.Resource.Igniter.add_block(
        &1,
        user,
        :changes,
        "change #{inspect(assign_role)}, on: [:create]"
      )
    )
  end

  defp add_user_policies(igniter, assigns) do
    user = assigns[:user]

    Edits.unless_contains(igniter, user, "policy action(:set_role)", fn igniter ->
      igniter
      # The installer's catch-all is not there in every version; the
      # AshAuthentication bypass stays first either way.
      |> Edits.remove_forbid_all_policy(user)
      |> Ash.Resource.Igniter.add_block(
        user,
        :policies,
        Gen.render_template("saas/accounts/user/policies.eex", assigns)
      )
    end)
  end

  defp add_resources(igniter, assigns) do
    accounts = assigns[:accounts]

    igniter =
      Gen.create_modules(
        igniter,
        Enum.map(@resources, fn name ->
          {Module.concat(accounts, name),
           "saas/accounts/#{name |> to_string() |> Macro.underscore()}.ex.eex"}
        end),
        assigns
      )

    igniter = create_support_modules(igniter, assigns)

    Enum.reduce(@resources, igniter, fn name, igniter ->
      Ash.Domain.Igniter.add_resource_reference(igniter, accounts, Module.concat(accounts, name))
    end)
  end

  defp create_support_modules(igniter, assigns) do
    accounts = assigns[:accounts]

    modules =
      Enum.map(@changes -- [:AssignRole], fn name ->
        {Module.concat([accounts, Changes, name]),
         "saas/accounts/changes/#{name |> to_string() |> Macro.underscore()}.ex.eex"}
      end) ++
        [
          {Module.concat([accounts, Validations, NotLastOwner]),
           "saas/accounts/validations/not_last_owner.ex.eex"},
          {Module.concat([accounts, Validations, SameOrganization]),
           "saas/accounts/validations/same_organization.ex.eex"},
          {Module.concat([accounts, Checks, ActorManagesOrganization]),
           "saas/accounts/checks/actor_manages_organization.ex.eex"}
        ]

    Gen.create_modules(igniter, modules, assigns)
  end

  # Versions of every Accounts resource live in the domain, and the organization
  # is exposed through JSON:API (`/api/organizations`, mounted by `Saas.Api`).
  defp configure_domain(igniter, assigns) do
    accounts = assigns[:accounts]

    igniter
    |> Spark.Igniter.add_extension(accounts, Ash.Domain, :extensions, AshPaperTrail.Domain)
    |> Spark.Igniter.add_extension(accounts, Ash.Domain, :extensions, AshJsonApi.Domain)
    |> Spark.Igniter.set_option(accounts, [:paper_trail, :include_versions?], true)
  end

  defp add_managers(igniter, assigns) do
    accounts = assigns[:accounts]

    Edits.unless_contains(igniter, accounts, "def managers(", fn igniter ->
      Edits.append_to_module(
        igniter,
        accounts,
        Gen.render_template("saas/accounts/managers.eex", assigns)
      )
    end)
  end

  defp remove_magic_link_route(igniter, assigns) do
    Edits.remove_call(igniter, assigns[:router], :magic_sign_in_route, [2, 3, 4])
  end

  defp add_organization_web(igniter, assigns) do
    web = assigns[:web]

    Gen.create_modules(
      igniter,
      [
        {Module.concat(web, OrganizationController),
         "saas/accounts/organization_controller.ex.eex"},
        {Module.concat(web, LiveOrganization), "saas/accounts/live_organization.ex.eex"}
      ],
      assigns
    )
  end
end
