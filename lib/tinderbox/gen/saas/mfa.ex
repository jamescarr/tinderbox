defmodule Tinderbox.Gen.Saas.Mfa do
  @moduledoc """
  Multi-factor authentication for the SaaS stack, for the two setups a SaaS meets:
  self-hosted (TOTP in the app) and an identity provider that already does MFA
  (Okta, Entra, Auth0, Keycloak).

  People turn it on, with recovery codes, at `/settings/security`; platform admins
  see everyone's status and reset it at `/admin/security`. `MFA_REQUIRED=true`
  sends everyone without a factor to set one up at their next sign-in.
  `MFA_SSO=idp` trusts the MFA the identity provider reports in the OIDC ID token
  (`amr`/`acr`), and `SSO_ACR_VALUES` asks the provider to step the user up. See the
  comment block in the generated `config/runtime.exs`.

  Generated, with `<App>.Accounts.MFA` as the facade the application calls:

    * `<App>.Vault` - AES-GCM encryption at rest (AshCloak), keyed by `CLOAK_KEY`;
      a vault the project already has is used as it is,
    * `<App>.Accounts.MfaFactor` - the factor: encrypted TOTP secret, hashed
      recovery codes, failure counter and lockout,
    * `<App>.Accounts.MFA` - the policy (what a sign-in leads to, who may turn it
      off), and `<App>.Accounts.MFA.Provider`, the behaviour a different factor
      implements; `<App>.Accounts.MFA.Totp` is the default,
    * `<App>.Accounts.Changes.RecordSsoAssurance` - carries the ID token's
      `amr`/`acr` to the sign-in callback; the SSO strategy asks for `acr_values`,
    * `<App>Web.AuthController` - the installer's, with `success/4` handing the user
      to `<App>Web.MfaController` (`/mfa`, `/mfa/setup`) and `<App>Web.MfaHTML`
      when a code is needed. A controller that is no longer the installer's is left
      alone, with a warning saying what to call,
    * `<App>Web.SecurityLive` and `<App>Web.Admin.SecurityLive`, and their entries
      in the user menu and the admin navigation,
    * `config/runtime.exs` settings, and tests for the facade, the controller and the
      page, with `<App>.MFATestHelpers` (enrolling, right and wrong codes) in `test/support`.

  `apply/2` runs after `Tinderbox.Gen.Saas.Admin`, which creates the admin layout
  and the `:admin_routes` session it extends. `install/2` is the same for a SaaS
  project generated before this existed (`mix tinderbox.gen.mfa`). Edits to files
  that exist already are guarded, so running it twice changes nothing.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits

  @doc "The packages the generated code uses."
  @spec deps() :: [{atom(), String.t()}]
  def deps,
    do: [
      {:nimble_totp, "~> 1.0"},
      {:eqrcode, "~> 0.2"},
      {:cloak, "~> 1.1"},
      {:ash_cloak, "~> 0.4"}
    ]

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    accounts = assigns[:accounts]

    assigns =
      Keyword.merge(assigns,
        vault: Module.concat(assigns[:prefix], "Vault"),
        mfa: Module.concat(accounts, "MFA"),
        mfa_factor: Module.concat(accounts, "MfaFactor"),
        record_sso_assurance: Module.concat([accounts, Changes, RecordSsoAssurance]),
        auth_controller: Module.concat(assigns[:web], "AuthController")
      )

    igniter
    |> add_vault(assigns)
    |> create_modules(assigns)
    |> wire_sso(assigns)
    |> gate_sign_in(assigns)
    |> add_routes(assigns)
    |> add_navigation(assigns)
    |> add_runtime_config(assigns)
    |> add_tests(assigns)
  end

  @doc """
  Adds multi-factor authentication to a project generated with `--stack saas`
  before it existed: what `mix tinderbox.gen.mfa` runs. Raises when the project
  is not a SaaS project, or already has it.
  """
  @spec install(Igniter.t(), keyword()) :: Igniter.t()
  def install(igniter, opts) do
    {igniter, assigns} = Tinderbox.Gen.Saas.assigns(igniter, opts)
    live_organization = Module.concat(assigns[:web], "LiveOrganization")
    mfa = Module.concat(assigns[:accounts], "MFA")

    {saas?, igniter} = Igniter.Project.Module.module_exists(igniter, live_organization)

    unless saas? do
      Mix.raise(
        "mix tinderbox.gen.mfa adds multi-factor authentication to a project generated " <>
          "with --stack saas, and #{inspect(live_organization)} is missing."
      )
    end

    {mfa?, igniter} = Igniter.Project.Module.module_exists(igniter, mfa)

    if mfa? do
      Mix.raise("#{inspect(mfa)} already exists: this project has multi-factor authentication.")
    end

    igniter
    |> add_deps()
    |> __MODULE__.apply(assigns)
    |> Ash.Igniter.codegen("add_mfa")
    # Same reason as in `Tinderbox.Gen.Saas.generate/2`: Ash formats the migration
    # once, and `mix format --check-formatted` would fail on the fresh file.
    |> Igniter.add_task("format", ["priv/repo/migrations/*add_mfa.exs"])
    |> Igniter.add_notice(
      "Multi-factor authentication added: people manage it at /settings/security, " <>
        "admins at /admin/security. Run `mix ash.migrate`. Production needs CLOAK_KEY " <>
        "(openssl rand -base64 32); MFA_REQUIRED, MFA_SSO and SSO_ACR_VALUES are " <>
        "described in config/runtime.exs."
    )
  end

  # Only `mix igniter.install` installs a task's `adds_deps`; run directly, the task
  # adds them to mix.exs itself. `Igniter.do_or_dry_run/2` runs `mix deps.get` before
  # the queued tasks, so the `mix ash.codegen` subprocess compiles them.
  defp add_deps(igniter) do
    Enum.reduce(deps(), igniter, &Igniter.Project.Deps.add_dep(&2, &1, on_exists: :skip))
  end

  # -- vault ----------------------------------------------------------------

  # A project may have its own vault (`<App>.Vault`, already supervised and
  # configured): it is used as it is, with no second child and no second key.
  defp add_vault(igniter, assigns) do
    vault = assigns[:vault]

    case Igniter.Project.Module.module_exists(igniter, vault) do
      {true, igniter} ->
        igniter

      {false, igniter} ->
        igniter
        |> Igniter.Project.Module.create_module(vault, render("vault.ex.eex", assigns))
        |> Igniter.Project.Application.add_new_child(vault, after: [assigns[:repo]])
    end
  end

  # -- modules ----------------------------------------------------------------

  defp create_modules(igniter, assigns) do
    web = assigns[:web]
    mfa = assigns[:mfa]

    modules = [
      {assigns[:mfa_factor], "saas/mfa/mfa_factor.ex.eex"},
      {Module.concat(mfa, "Provider"), "saas/mfa/provider.ex.eex"},
      {mfa, "saas/mfa/mfa.ex.eex"},
      {Module.concat(mfa, "Totp"), "saas/mfa/totp.ex.eex"},
      {assigns[:record_sso_assurance], "saas/mfa/record_sso_assurance.ex.eex"},
      {Module.concat(web, "MfaController"), "saas/mfa/mfa_controller.ex.eex"},
      {Module.concat(web, "MfaHTML"), "saas/mfa/mfa_html.ex.eex"},
      {Module.concat(web, "SecurityLive"), "saas/mfa/security_live.ex.eex"},
      {Module.concat([web, "Admin", "SecurityLive"]), "saas/mfa/admin_security_live.ex.eex"}
    ]

    igniter
    |> Gen.create_modules(modules, assigns)
    |> Ash.Domain.Igniter.add_resource_reference(assigns[:accounts], assigns[:mfa_factor])
  end

  # -- SSO -------------------------------------------------------------------

  # The strategy's `authorization_params` becomes a secret so `SSO_ACR_VALUES` can
  # add `acr_values` at runtime, and the register action records the ID token's
  # `amr`/`acr` for `MFA.sign_in_step/2`.
  defp wire_sso(igniter, assigns) do
    user = assigns[:user]
    secrets = assigns[:secrets]
    record_sso_assurance = assigns[:record_sso_assurance]

    igniter
    |> Edits.ensure_secret_from_env(
      secrets,
      user,
      [:authentication, :strategies, :sso, :authorization_params],
      :sso_authorization_params
    )
    |> Edits.put_strategy_option(
      user,
      :oidc,
      :sso,
      :authorization_params,
      inspect(secrets)
    )
    |> Edits.unless_contains(user, inspect(record_sso_assurance), fn igniter ->
      Ash.Resource.Igniter.add_block(
        igniter,
        user,
        :changes,
        "change #{inspect(record_sso_assurance)}, on: [:create], " <>
          "where: [action_is(:register_with_sso)]"
      )
    end)
  end

  # -- sign-in -----------------------------------------------------------------

  # The installer's AuthController finishes the sign-in itself. Ours hands the
  # user to `MfaController` first. A controller that is no longer the installer's
  # (the assign-name comment is gone) is the developer's, and is left alone.
  defp gate_sign_in(igniter, assigns) do
    auth_controller = assigns[:auth_controller]
    mfa = assigns[:mfa]
    web = assigns[:web]

    igniter =
      Gen.replace_module(
        igniter,
        auth_controller,
        render("auth_controller.ex.eex", assigns),
        &(String.contains?(
            &1,
            "If your resource has a different name, update the assign name here"
          ) and not String.contains?(&1, "MFA"))
      )

    {igniter, gated?} = Edits.source_contains?(igniter, auth_controller, "MFA.sign_in_step")

    if gated? do
      igniter
    else
      Igniter.add_warning(
        igniter,
        "#{inspect(auth_controller)} is not the one ash_authentication_phoenix generated, " <>
          "so multi-factor authentication was not wired into it. In success/4, call " <>
          "#{inspect(mfa)}.sign_in_step(user, activity) and pass :challenge/:enroll to " <>
          "#{inspect(web)}.MfaController.start/4 and :complete to " <>
          "#{inspect(web)}.MfaController.complete_sign_in/4."
      )
    end
  end

  # -- routes -------------------------------------------------------------------

  defp add_routes(igniter, assigns) do
    router = assigns[:router]

    igniter
    |> add_mfa_routes(router, assigns[:web])
    |> add_live_route(
      router,
      :authenticated_routes,
      ~s(live "/settings/security", SecurityLive)
    )
    |> add_live_route(router, :admin_routes, ~s(live "/security", Admin.SecurityLive))
  end

  # Plain controller routes: the user is not signed in yet.
  defp add_mfa_routes(igniter, router, web) do
    Edits.unless_contains(igniter, router, "MfaController", fn igniter ->
      Igniter.Libs.Phoenix.append_to_scope(
        igniter,
        "/",
        """
        get "/mfa", MfaController, :challenge
        post "/mfa", MfaController, :verify
        get "/mfa/setup", MfaController, :setup
        post "/mfa/setup", MfaController, :confirm
        post "/mfa/cancel", MfaController, :cancel
        """,
        with_pipelines: [:browser],
        arg2: web,
        router: router
      )
    end)
  end

  defp add_live_route(igniter, router, session, code) do
    Edits.unless_contains(
      igniter,
      router,
      code,
      &Edits.add_to_live_session(&1, router, session, code)
    )
  end

  # -- navigation ----------------------------------------------------------------

  # The layouts are generated by `Saas.Web` and `Saas.Admin`, and these entries
  # are added here rather than there: a project that already has the layouts gets
  # the same entries from the same code.
  defp add_navigation(igniter, assigns) do
    web = assigns[:web]

    igniter
    |> Gen.rewrite_module(Module.concat(web, "Layouts"), &add_user_menu_entry(&1, web))
    |> Gen.rewrite_module(Module.concat([web, "Admin", "Layouts"]), &add_admin_nav(&1, web))
  end

  @user_menu_anchor ~s(<:item navigate={~p"/settings/notifications"}>Notification settings</:item>)
  @user_menu_entry ~s(<:item navigate={~p"/settings/security"}>Security</:item>)

  defp add_user_menu_entry(content, web) do
    layouts = Module.concat(web, "Layouts")

    cond do
      String.contains?(content, ~s(~p"/settings/security")) ->
        {:ok, content}

      new = insert_line(content, @user_menu_anchor, @user_menu_entry, :after) ->
        {:ok, new}

      true ->
        {:warning,
         "Could not add Security to the user menu in #{inspect(layouts)}; " <>
           ~s(link ~p"/settings/security" by hand.)}
    end
  end

  @admin_nav_entry ~s(<.nav_item navigate={~p"/admin/security"} icon="hero-key" active={@current_page == :security}>Two-factor</.nav_item>)

  defp add_admin_nav(content, web) do
    admin_layouts = Module.concat([web, "Admin", "Layouts"])

    # All three edits, or none.
    with false <- String.contains?(content, ~s(security: "Security")),
         {:ok, content} <-
           replace_once(
             content,
             ~s(subscriptions: "Subscriptions"),
             ~s(subscriptions: "Subscriptions",\nsecurity: "Security")
           ),
         {:ok, content} <-
           replace_once(
             content,
             ":organizations, :subscriptions]",
             ":organizations, :subscriptions, :security]"
           ),
         new when is_binary(new) <-
           insert_line(content, ~s(<.nav_item href={~p"/admin/flags"}), @admin_nav_entry, :before) do
      {:ok, new}
    else
      true ->
        {:ok, content}

      _missing_anchor ->
        {:warning,
         "Could not add the Two-factor page to #{inspect(admin_layouts)}: add :security to " <>
           "@titles and to current_page's values, and a nav_item for " <>
           ~s(~p"/admin/security".)}
    end
  end

  defp replace_once(content, pattern, replacement) do
    if String.contains?(content, pattern) do
      {:ok, String.replace(content, pattern, replacement, global: false)}
    else
      :error
    end
  end

  # Inserts `line` before or after the first line containing `anchor`, with that
  # line's indentation; `nil` when no line does.
  defp insert_line(content, anchor, line, placement) do
    lines = String.split(content, "\n")

    case Enum.find_index(lines, &String.contains?(&1, anchor)) do
      nil ->
        nil

      index ->
        [indent] = Regex.run(~r/^\s*/, Enum.at(lines, index))
        at = if placement == :after, do: index + 1, else: index

        lines |> List.insert_at(at, indent <> line) |> Enum.join("\n")
    end
  end

  # -- runtime config ---------------------------------------------------------------

  defp add_runtime_config(igniter, assigns) do
    app = assigns[:app]

    igniter
    # Also skips a project whose own vault is configured already.
    |> Gen.append_to_runtime_exs(
      render("vault_runtime.exs.eex", assigns),
      Gen.runtime_configures?(app, [assigns[:vault]])
    )
    |> Gen.append_to_runtime_exs(
      render("runtime_config.exs.eex", assigns),
      Gen.runtime_configures?(app, [:sso_authorization_params])
    )
  end

  # -- tests ---------------------------------------------------------------------------

  # `:test_support` drops the app prefix, so `<App>.MFATestHelpers` lands in
  # `test/support/mfa_test_helpers.ex`, next to `<App>.Fixtures`.
  defp add_tests(igniter, assigns) do
    app = assigns[:app]

    igniter =
      Gen.create_modules(
        igniter,
        [
          {Module.concat(assigns[:prefix], "MFATestHelpers"), "saas/mfa/mfa_test_helpers.ex.eex"}
        ],
        assigns,
        location: :test_support
      )

    [
      {"test/#{app}/accounts/mfa_test.exs", "mfa_test.exs.eex"},
      {"test/#{app}_web/controllers/mfa_controller_test.exs", "mfa_controller_test.exs.eex"},
      {"test/#{app}_web/live/security_live_test.exs", "security_live_test.exs.eex"}
    ]
    |> Enum.reduce(igniter, fn {path, template}, igniter ->
      Igniter.create_new_file(igniter, path, render(template, assigns))
    end)
  end

  defp render(template, assigns), do: Gen.render_template("saas/mfa/#{template}", assigns)
end
