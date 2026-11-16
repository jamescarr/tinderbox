defmodule Tinderbox.Gen.SaasIntegrationsTest do
  # The Ash domain list is read from the application env, which is global.
  use ExUnit.Case, async: false

  import Igniter.Test
  import Tinderbox.Test.SaasFixtures
  import Tinderbox.Test.SourceHelpers

  alias Tinderbox.Gen.Saas

  @router "lib/test_web/router.ex"
  @layouts "lib/test_web/components/layouts.ex"
  @endpoint_path "lib/test_web/endpoint.ex"
  @fixtures "test/support/fixtures.ex"

  setup_all do
    Application.put_env(:test, :ash_domains, [Test.Accounts])
    on_exit(fn -> Application.delete_env(:test, :ash_domains) end)

    {:ok, igniter: Saas.apply(saas_project(), integrations: true)}
  end

  test "--integrations alone brings the file drop too", %{igniter: igniter} do
    for path <- ~w(
          lib/test/file_drop.ex
          lib/test/file_drop/upload.ex
          lib/test/integrations.ex
          lib/test/integrations/connector.ex
          lib/test/integrations/source.ex
          lib/test/integrations/record.ex
          lib/test/integrations/handler.ex
          lib/test/integrations/drop_handler.ex
          lib/test/integrations/connectors/webhook.ex
          lib/test/integrations/changes/setup_source.ex
          lib/test/integrations/changes/sync.ex
          lib/test/integrations/changes/process.ex
          lib/test/integrations/changes/broadcast.ex
          lib/test_web/plugs/integration_webhook.ex
          lib/test_web/integrations_live.ex
          test/test/integrations_test.exs
          test/test_web/integration_webhook_test.exs
          test/test_web/live/integrations_live_test.exs
        ) do
      assert_creates(igniter, path)
    end

    assert_has(source(igniter, "lib/test/integrations/source.ex"), "vault Test.Vault")
  end

  test "the webhook plug sits between Stripe's and Plug.Parsers", %{igniter: igniter} do
    endpoint = source(igniter, @endpoint_path)
    plug = ~s|plug TestWeb.Plugs.IntegrationWebhook, at: "/webhooks/integrations"|

    assert_has(endpoint, plug)
    assert order(endpoint, "plug Stripe.WebhookPlug") < order(endpoint, plug)
    assert order(endpoint, plug) < order(endpoint, "plug Plug.Parsers")
  end

  test "config: the domain, its queue, the catalog, and the connectors take dropped files", %{
    igniter: igniter
  } do
    config = source(igniter, "config/config.exs")

    assert_has(config, "Test.Integrations,")
    assert_has(config, "integrations: 5")
    assert_has(config, "connectors: [Test.Integrations.Connectors.Webhook]")
    assert_has(config, "webhook_max_bytes: 5_000_000")
    assert_has(config, "handler: Test.Integrations.DropHandler")
    refute_has(config, "Test.FileDrop.Handlers.Keep")
    refute Enum.any?(igniter.warnings, &(&1 =~ "handler of its own"))
  end

  test "routes /integrations and lists it after Files", %{igniter: igniter} do
    assert_has(source(igniter, @router), ~s|live "/integrations", IntegrationsLive|)

    layouts = source(igniter, @layouts)
    assert order(layouts, ~s|~p"/drop"|) < order(layouts, ~s|~p"/integrations"|)

    assert order(layouts, ~s|~p"/integrations"|) <
             order(layouts, ~s|<.nav_section :if={@current_user.role == :admin}|)

    assert_has(source(igniter, @fixtures), "def source_fixture(organization, user")
  end

  test "applying twice changes nothing", %{igniter: igniter} do
    again = Saas.apply(igniter, integrations: true)

    for path <- [
          @router,
          @layouts,
          @endpoint_path,
          "config/config.exs",
          "config/runtime.exs",
          @fixtures
        ] do
      assert source(again, path) == source(igniter, path), "#{path} changed on the second run"
    end
  end

  test "a file drop handler of the project's own is left alone, with a warning" do
    igniter =
      saas_project()
      |> Saas.apply(file_drop: true)
      |> Igniter.Project.Config.configure(
        "config.exs",
        :test,
        [Test.FileDrop, :handler],
        Test.Statements.Handler
      )
      |> Igniter.compose_task(Mix.Tasks.Tinderbox.Gen.Integrations, [])

    config = source(igniter, "config/config.exs")
    assert_has(config, "handler: Test.Statements.Handler")
    refute_has(config, "handler: Test.Integrations.DropHandler")

    assert [warning] = Enum.filter(igniter.warnings, &(&1 =~ "handler of its own"))
    assert warning =~ "Test.Integrations.DropHandler.handle/2"
  end

  describe "mix tinderbox.gen.integrations" do
    test "refuses a project that is not a SaaS project" do
      assert_raise Mix.Error, ~r/--stack saas/, fn ->
        Igniter.compose_task(saas_project(), Mix.Tasks.Tinderbox.Gen.Integrations, [])
      end
    end

    test "refuses a project that has it", %{igniter: igniter} do
      assert_raise Mix.Error, ~r/already exists: this project has integrations/, fn ->
        Igniter.compose_task(igniter, Mix.Tasks.Tinderbox.Gen.Integrations, [])
      end
    end

    test "refuses a project without the vault that encrypts credentials" do
      organization = "defmodule TestWeb.LiveOrganization do\nend\n"
      project = saas_project(files: [{"lib/test_web/live_organization.ex", organization}])

      assert_raise Mix.Error, ~r/Test.Vault is missing: run mix tinderbox.gen.mfa first/, fn ->
        Igniter.compose_task(project, Mix.Tasks.Tinderbox.Gen.Integrations, [])
      end
    end

    test "on a project with the file drop, adds only integrations" do
      with_file_drop = Saas.apply(saas_project(), file_drop: true)

      igniter =
        Igniter.compose_task(with_file_drop, Mix.Tasks.Tinderbox.Gen.Integrations, [])

      assert_creates(igniter, "lib/test/integrations.ex")

      assert source(igniter, "lib/test/file_drop.ex") ==
               source(with_file_drop, "lib/test/file_drop.ex")

      assert codegen?(igniter, "add_integrations")
      refute Enum.any?(igniter.notices, &(&1 =~ "File drop added"))
    end

    test "on a project without it, adds both" do
      igniter =
        saas_project()
        |> Saas.apply([])
        |> Igniter.compose_task(Mix.Tasks.Tinderbox.Gen.Integrations, [])

      assert_creates(igniter, "lib/test/file_drop.ex")
      assert_creates(igniter, "lib/test/integrations.ex")
      assert_has(source(igniter, "config/config.exs"), "handler: Test.Integrations.DropHandler")
      assert codegen?(igniter, "add_integrations")
      assert_has_notice(igniter, &(&1 =~ "File drop added"))
      assert_has_notice(igniter, &(&1 =~ "POST /webhooks/integrations/<source id>"))
    end
  end

  defp codegen?(igniter, name) do
    Enum.any?(igniter.tasks, fn
      {"ash.codegen", [codegen | _]} -> codegen =~ name
      _task -> false
    end)
  end
end
