defmodule Tinderbox.Gen.SaasTest do
  # The Ash domain list is read from the application env, which is global.
  use ExUnit.Case, async: false

  import Igniter.Test
  import Tinderbox.Test.SaasFixtures

  alias Tinderbox.Gen.Saas

  # A project's formatter (`import_deps`) strips the parentheses Igniter's own
  # formatting puts around DSL calls; these tests run without it, so sources and
  # expectations are compared with parentheses removed.
  defguardp is_snippet(value) when is_binary(value)

  setup_all do
    Application.put_env(:test, :ash_domains, [Test.Accounts])
    on_exit(fn -> Application.delete_env(:test, :ash_domains) end)

    {:ok, igniter: Saas.apply(saas_project(), [])}
  end

  test "creates the accounts, billing, notification and event modules", %{igniter: igniter} do
    for path <- ~w(
          lib/test/accounts/organization.ex
          lib/test/accounts/membership.ex
          lib/test/accounts/invitation.ex
          lib/test/accounts/changes/set_slug.ex
          lib/test/accounts/validations/not_last_owner.ex
          lib/test/accounts/checks/actor_manages_organization.ex
          lib/test/billing.ex
          lib/test/billing/plans.ex
          lib/test/billing/subscription.ex
          lib/test/billing/stripe_event.ex
          lib/test/billing/changes/sync_subscription.ex
          lib/test/notifications.ex
          lib/test/notifications/notification.ex
          lib/test/notifications/preference.ex
          lib/test/notifications/adapters/local.ex
          lib/test/events.ex
          lib/test/events/stream_bootstrap.ex
          lib/test/events/consumer.ex
          lib/test/events/ash_notifier.ex
          lib/test/prom_ex.ex
          lib/test/feature_flags.ex
          lib/test_web/dashboard_live.ex
          lib/test_web/inbox_live.ex
          lib/test_web/billing_live.ex
          lib/test_web/admin/dashboard_live.ex
          lib/test_web/admin/users_live.ex
          lib/test_web/health_controller.ex
          lib/test_web/organization_controller.ex
          lib/test_web/stripe_webhook_handler.ex
          .github/workflows/ci.yml
          priv/repo/migrations/20250101000000_create_fun_with_flags_toggles.exs
        ) do
      assert_creates(igniter, path)
    end
  end

  test "the user signs in with a password or SSO and can be an admin", %{igniter: igniter} do
    user = source(igniter, "lib/test/accounts/user.ex")

    assert_has(user, "attribute :role, :atom")
    assert_has(user, "oidc :sso do")
    assert_has(user, "create :register_with_sso do")
    assert_has(user, "update :set_role do")
    assert_has(user, "change Test.Accounts.Changes.AssignRole, on: [:create]")
    assert_has(user, "has_many :memberships, Test.Accounts.Membership")
    assert_has(user, "create_timestamp :created_at")
    refute_has(user, "forbid_if always()")

    # An SSO-only user has no password.
    assert [_before, attribute] =
             String.split(plain(user), "attribute :hashed_password", parts: 2)

    assert attribute |> String.split("end", parts: 2) |> hd() =~ "allow_nil? true"
  end

  test "the SSO strategy reads its settings from secrets backed by the runtime config",
       %{igniter: igniter} do
    secrets = source(igniter, "lib/test/secrets.ex")

    for {option, key} <- [
          client_id: "sso_client_id",
          client_secret: "sso_client_secret",
          redirect_uri: "sso_redirect_uri",
          base_url: "sso_base_url"
        ] do
      assert_has(secrets, "[:authentication, :strategies, :sso, :#{option}]")
      assert_has(secrets, "Application.fetch_env(:test, :#{key})")
    end

    runtime = source(igniter, "config/runtime.exs")

    assert_has(runtime, ~s|System.get_env("SSO_BASE_URL", "http://localhost:5556/dex")|)
    assert_has(runtime, "admin_emails")
  end

  test "ADMIN_EMAILS is only defaulted outside production", %{igniter: igniter} do
    runtime = source(igniter, "config/runtime.exs")

    assert_has(runtime, ~s|if(config_env() == :prod, do: "", else: "admin@example.com")|)
  end

  test "the router has the app's routes and loses the magic link route", %{igniter: igniter} do
    router = source(igniter, "lib/test_web/router.ex")

    for route <- [
          ~s|live "/dashboard", DashboardLive|,
          ~s|live "/billing", BillingLive|,
          ~s|live "/inbox", InboxLive|,
          ~s|post "/organizations/switch", OrganizationController, :switch|,
          ~s|get "/health", HealthController, :show|,
          ~s|scope "/admin", TestWeb|,
          "ash_authentication_live_session :admin_routes",
          ~s|live "/users", Admin.UsersLive|,
          ~s|scope "/admin/flags"|,
          "FunWithFlags.UI.Router",
          "plug TestWeb.Plugs.RequireAdmin"
        ] do
      assert_has(router, route)
    end

    refute_has(router, "magic_sign_in_route")
  end

  test "the JSON:API router is mounted at /api", %{igniter: igniter} do
    router = source(igniter, "lib/test_web/router.ex")

    assert_has(router, ~s|scope "/api"|)
    assert_has(router, "forward \"/\", TestWeb.AshJsonApiRouter")
    assert_has(source(igniter, "lib/test_web/ash_json_api_router.ex"), "Test.Accounts")
  end

  test "the endpoint verifies Stripe's signature before the body is parsed", %{igniter: igniter} do
    endpoint = source(igniter, "lib/test_web/endpoint.ex")

    assert order(endpoint, "plug Stripe.WebhookPlug") < order(endpoint, "plug Plug.Parsers")
    assert_has(endpoint, "secret: {Application, :get_env, [:test, :stripe_webhook_secret]}")
    assert order(endpoint, "plug PromEx.Plug") < order(endpoint, "plug Plug.RequestId")
  end

  test "the supervision tree starts metrics first and NATS before its consumers",
       %{igniter: igniter} do
    application = source(igniter, "lib/test/application.ex")

    assert order(application, "Test.PromEx") < order(application, "TestWeb.Telemetry")
    assert order(application, "Test.Repo") < order(application, "Gnat.ConnectionSupervisor")

    assert order(application, "Gnat.ConnectionSupervisor") <
             order(application, "Test.Events.StreamBootstrap")

    assert order(application, "Test.Events.StreamBootstrap") <
             order(application, "Test.Events.Consumer")

    # Tracing is instrumented before anything can emit a span.
    assert order(application, "OpentelemetryPhoenix.setup") < order(application, "children = [")
    assert_has(application, "OpentelemetryPhoenix.setup(adapter: :bandit)")
    assert_has(application, "OpentelemetryEcto.setup([:test, :repo])")
  end

  test "runtime config covers Stripe, SSO, SMTP and tracing", %{igniter: igniter} do
    runtime = source(igniter, "config/runtime.exs")

    assert_has(runtime, "config :stripity_stripe, api_key:")
    assert_has(runtime, ~s|System.get_env("STRIPE_PRICE_STARTER", "price_replace_me")|)
    assert_has(runtime, "stripe_configured?")
    assert_has(runtime, "sso_client_id")
    assert_has(runtime, "mail_from")
    assert_has(runtime, "config :test, :nats, %{")
    assert_has(runtime, "config :opentelemetry")

    # SMTP must not replace the test mailer.
    assert order(runtime, "if config_env() != :test do") < order(runtime, "Swoosh.Adapters.SMTP")
  end

  test "config.exs registers the domains, the flag store and the extra queues",
       %{igniter: igniter} do
    config = source(igniter, "config/config.exs")

    assert_has(config, "FunWithFlags.Store.Persistent.Ecto")
    assert_has(config, "FunWithFlags.Notifications.PhoenixPubSub")
    assert_has(config, "billing: 5")
    assert_has(config, "notifications: 10")
    assert_has(config, "Test.Billing")
    assert_has(config, "Test.Notifications")
    assert_has(config, "default: 10")
  end

  test "the stylesheet and script load Petal Components", %{igniter: igniter} do
    css = source(igniter, "assets/css/app.css")
    js = source(igniter, "assets/js/app.js")

    assert css =~ ~s|@import "../../deps/petal_components/assets/default.css";|
    assert css =~ ~s|@source "../../deps/petal_components/**/*.*ex";|
    assert js =~ "import PetalComponents from"
    assert js =~ "hooks: {...colocatedHooks, ...PetalComponents}"
  end

  test "the layout and landing page know the signed-in user", %{igniter: igniter} do
    layouts = source(igniter, "lib/test_web/components/layouts.ex")

    assert_has(layouts, "attr :current_user")
    assert_has(layouts, ~s|action={~p"/organizations/switch"}|)
    assert_has(layouts, "def flash_group(assigns)")
    assert_has(layouts, "def theme_toggle(assigns)")

    assert source(igniter, "test/test_web/controllers/page_controller_test.exs") =~
             ~s|=~ "Sign in"|

    assert source(igniter, "lib/test_web/controllers/page_html/home.html.heex") =~
             "Go to dashboard"
  end

  test "the web module gains the Petal helpers next to the daisyUI ones", %{igniter: igniter} do
    web = source(igniter, "lib/test_web.ex")

    assert_has(web, "def admin_live_view do")
    assert_has(web, "def admin_html do")
    assert_has(web, "use PetalComponents")
    assert_has(web, "import TestWeb.CoreComponents")
    # CoreComponents stay out of the admin helpers: both define `button/1` and `table/1`.
    assert [_html, admin] = String.split(web, "defp admin_html_helpers", parts: 2)
    refute admin =~ "import TestWeb.CoreComponents"
  end

  test "the Accounts domain carries versions and JSON:API", %{igniter: igniter} do
    accounts = source(igniter, "lib/test/accounts.ex")

    assert_has(accounts, "AshPaperTrail.Domain")
    assert_has(accounts, "AshJsonApi.Domain")
    assert_has(accounts, "include_versions?")

    for resource <- ~w(Organization Membership Invitation UserIdentity) do
      assert_has(accounts, "resource Test.Accounts.#{resource}")
    end
  end

  test "queues the release image, one migration run and the notices", %{igniter: igniter} do
    assert {"phx.gen.release", ["--docker"]} in igniter.tasks
    assert Enum.any?(igniter.tasks, &match?({"ash.codegen", [name | _]} when is_binary(name), &1))

    # Ash's own formatting of the migration is not stable, and CI checks formatting.
    names = Enum.map(igniter.tasks, &elem(&1, 0))

    assert Enum.find_index(names, &(&1 == "format")) >
             Enum.find_index(names, &(&1 == "ash.codegen"))

    assert_has_notice(igniter, &(&1 =~ "mise trust && mise run dev"))
    assert_has_notice(igniter, &(&1 =~ "Stripe: create two recurring Prices"))
  end

  test "adds the storage dependencies the Phoenix project lacks and keeps its req", %{
    igniter: igniter
  } do
    mix_exs = source(igniter, "mix.exs")

    assert_has(mix_exs, ~s|{:ex_aws, "~> 2.7"}|)
    assert_has(mix_exs, ~s|{:req, "~> 0.5"}|)
    refute_has(mix_exs, ~s|{:req, "~> 0.7"}|)
  end

  test "FunWithFlags starts in the app's tree and still ships in a release", %{igniter: igniter} do
    mix_exs = source(igniter, "mix.exs")

    # `included_applications` would make `mix release` fail: `fun_with_flags_ui`
    # needs `:fun_with_flags` as a regular application.
    assert_has(mix_exs, "releases:")
    assert_has(mix_exs, "applications: [fun_with_flags: :load, fun_with_flags_ui: :load]")
    refute_has(mix_exs, "included_applications")
    assert_has(source(igniter, "lib/test/application.ex"), "FunWithFlags.Supervisor")
  end

  test "generating twice leaves the files the installers wrote exactly as after the first run",
       %{igniter: igniter} do
    again = Saas.apply(igniter, [])

    for path <- ~w(
          lib/test_web/router.ex
          lib/test_web/endpoint.ex
          lib/test/application.ex
          lib/test_web.ex
          lib/test/accounts/user.ex
          lib/test/accounts.ex
          lib/test/secrets.ex
          assets/css/app.css
          assets/js/app.js
          config/runtime.exs
          config/config.exs
          mix.exs
        ) do
      assert source(again, path) == source(igniter, path), "#{path} changed on the second run"
    end
  end

  test "refuses a project without Phoenix" do
    assert_raise Mix.Error, ~r/requires a Phoenix project/, fn ->
      Saas.apply(test_project(), [])
    end
  end

  defp source(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  defp plain(string) when is_snippet(string) do
    string |> String.replace(["(", ")"], " ") |> String.replace(~r/\s+/, " ")
  end

  defp assert_has(source, snippet) do
    assert plain(source) =~ plain(snippet), "expected #{inspect(snippet)} in:\n#{source}"
  end

  defp refute_has(source, snippet) do
    refute plain(source) =~ plain(snippet), "did not expect #{inspect(snippet)} in:\n#{source}"
  end

  defp order(string, substring) do
    case :binary.match(plain(string), plain(substring)) do
      {index, _length} -> index
      :nomatch -> flunk("expected #{inspect(substring)} in:\n#{string}")
    end
  end
end
