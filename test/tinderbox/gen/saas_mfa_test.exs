defmodule Tinderbox.Gen.SaasMfaTest do
  # The Ash domain list is read from the application env, which is global.
  use ExUnit.Case, async: false

  import Igniter.Test
  import Tinderbox.Test.SaasFixtures
  import Tinderbox.Test.SourceHelpers

  alias Tinderbox.Gen.Saas

  @auth_controller "lib/test_web/controllers/auth_controller.ex"
  @installer_comment "# If your resource has a different name, update the assign name here (i.e :current_admin)"

  setup_all do
    Application.put_env(:test, :ash_domains, [Test.Accounts])
    on_exit(fn -> Application.delete_env(:test, :ash_domains) end)

    {:ok, igniter: Saas.apply(saas_project(), [])}
  end

  test "creates the vault, the factor, the facade, its provider, the pages and the tests",
       %{igniter: igniter} do
    for path <- ~w(
          lib/test/vault.ex
          lib/test/accounts/mfa_factor.ex
          lib/test/accounts/mfa.ex
          lib/test/accounts/mfa/provider.ex
          lib/test/accounts/mfa/totp.ex
          lib/test/accounts/changes/record_sso_assurance.ex
          lib/test_web/mfa_controller.ex
          lib/test_web/mfa_html.ex
          lib/test_web/security_live.ex
          lib/test_web/admin/security_live.ex
          test/test/accounts/mfa_test.exs
          test/test_web/controllers/mfa_controller_test.exs
          test/test_web/live/security_live_test.exs
          test/support/mfa_test_helpers.ex
        ) do
      assert_creates(igniter, path)
    end

    assert_has(source(igniter, "lib/test/accounts.ex"), "resource Test.Accounts.MfaFactor")
  end

  test "signing in goes through the second factor", %{igniter: igniter} do
    controller = source(igniter, @auth_controller)

    assert_has(controller, "MFA.sign_in_step(user, activity)")
    assert_has(controller, "def failure(")
    assert_has(controller, "clear_session(:test)")
    refute_has(controller, "If your resource has a different name")
    refute Enum.any?(igniter.warnings, &(&1 =~ "not wired into it"))

    router = source(igniter, "lib/test_web/router.ex")

    for route <- [
          ~s|get "/mfa", MfaController, :challenge|,
          ~s|post "/mfa", MfaController, :verify|,
          ~s|get "/mfa/setup", MfaController, :setup|,
          ~s|post "/mfa/setup", MfaController, :confirm|,
          ~s|post "/mfa/cancel", MfaController, :cancel|,
          ~s|live "/security", Admin.SecurityLive|
        ] do
      assert_has(router, route)
    end

    # In the session of signed-in pages, not after it.
    security = ~s|live "/settings/security", SecurityLive|
    session = "ash_authentication_live_session :authenticated_routes"

    assert order(router, session) < order(router, security)

    [_before, after_session] = router |> plain() |> String.split(plain(session), parts: 2)
    [inside, _rest] = String.split(after_session, " end ", parts: 2)
    assert inside =~ plain(security)
  end

  test "SSO can ask the provider for MFA and accept what it reports", %{igniter: igniter} do
    user = source(igniter, "lib/test/accounts/user.ex")

    assert_has(user, "authorization_params Test.Secrets")
    refute_has(user, ~s|authorization_params scope: "openid profile email"|)

    assert_has(
      user,
      "change Test.Accounts.Changes.RecordSsoAssurance, on: [:create], where: [action_is(:register_with_sso)]"
    )

    secrets = source(igniter, "lib/test/secrets.ex")
    assert_has(secrets, "[:authentication, :strategies, :sso, :authorization_params]")
    assert_has(secrets, "Application.fetch_env(:test, :sso_authorization_params)")

    runtime = source(igniter, "config/runtime.exs")

    for snippet <- [
          "SSO_ACR_VALUES",
          "MFA_SSO",
          "MFA_REQUIRED",
          ~s|raise "environment variable CLOAK_KEY is missing|,
          "Cloak.Ciphers.AES.GCM"
        ] do
      assert_has(runtime, snippet)
    end
  end

  test "the user menu and the admin navigation link the pages", %{igniter: igniter} do
    layouts = source(igniter, "lib/test_web/components/layouts.ex")
    assert_has(layouts, ~s|~p"/settings/security"|)

    assert order(layouts, ~s|~p"/settings/notifications"|) <
             order(layouts, ~s|~p"/settings/security"|)

    admin = source(igniter, "lib/test_web/admin/layouts.ex")
    assert_has(admin, ~s|security: "Security"|)
    assert_has(admin, ":security]")
    assert_has(admin, ~s|~p"/admin/security"|)
    assert order(admin, ~s|~p"/admin/security"|) < order(admin, ~s|~p"/admin/flags"|)

    application = source(igniter, "lib/test/application.ex")
    assert order(application, "Test.Repo") < order(application, "Test.Vault")
  end

  test "a customized AuthController is left alone, with a warning" do
    custom = String.replace(files()[@auth_controller], "    #{@installer_comment}\n", "")
    refute custom == files()[@auth_controller]

    igniter = Saas.apply(saas_project(files: [{@auth_controller, custom}]), [])

    assert source(igniter, @auth_controller) == custom

    assert [warning] = Enum.filter(igniter.warnings, &(&1 =~ ~r/not wired into it/))
    assert warning =~ "TestWeb.MfaController.start/4"
  end

  test "a vault the project already has is used as it is" do
    vault = "defmodule Test.Vault do\n  use Cloak.Vault, otp_app: :test\nend\n"
    igniter = Saas.apply(saas_project(files: [{"lib/test/vault.ex", vault}]), [])

    assert source(igniter, "lib/test/vault.ex") == vault
    # No second child for a vault the project already supervises.
    refute_has(source(igniter, "lib/test/application.ex"), "Test.Vault")
    # Its key is the project's business only when it configured one.
    assert_has(source(igniter, "config/runtime.exs"), "Cloak.Ciphers.AES.GCM")
  end

  test "generating twice changes nothing", %{igniter: igniter} do
    again = Saas.apply(igniter, [])

    for path <- [
          @auth_controller,
          "lib/test_web/components/layouts.ex",
          "lib/test_web/admin/layouts.ex",
          "lib/test_web/router.ex",
          "lib/test/accounts/user.ex",
          "lib/test/secrets.ex",
          "lib/test/application.ex",
          "config/runtime.exs"
        ] do
      assert source(again, path) == source(igniter, path), "#{path} changed on the second run"
    end
  end

  describe "mix tinderbox.gen.mfa" do
    test "refuses a project that is not a SaaS project" do
      assert_raise Mix.Error, ~r/--stack saas/, fn ->
        Igniter.compose_task(saas_project(), Mix.Tasks.Tinderbox.Gen.Mfa, [])
      end
    end

    test "refuses a project that has it", %{igniter: igniter} do
      assert_raise Mix.Error,
                   ~r/already exists: this project has multi-factor authentication/,
                   fn -> Igniter.compose_task(igniter, Mix.Tasks.Tinderbox.Gen.Mfa, []) end
    end
  end
end
