defmodule Tinderbox.Gen.SaasPlaidTest do
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
  @source "lib/test/integrations/source.ex"
  @setup_source "lib/test/integrations/changes/setup_source.ex"
  @domain "lib/test/integrations.ex"
  @connector "lib/test/integrations/connectors/plaid.ex"
  @connector_behaviour "lib/test/integrations/connector.ex"

  setup_all do
    Application.put_env(:test, :ash_domains, [Test.Accounts])
    on_exit(fn -> Application.delete_env(:test, :ash_domains) end)

    {:ok, igniter: Saas.apply(saas_project(), plaid: true)}
  end

  test "--plaid brings integrations and the file drop", %{igniter: igniter} do
    for path <- ~w(
          lib/test/integrations.ex
          lib/test/file_drop.ex
          lib/test/integrations/connectors/plaid.ex
          lib/test/integrations/connectors/plaid/error.ex
          lib/test/integrations/connectors/plaid/client.ex
          lib/test/integrations/connectors/plaid/client/http.ex
          lib/test/integrations/connectors/plaid/client/fake.ex
          lib/test/integrations/connectors/plaid/webhook.ex
          lib/test/integrations/changes/disconnect.ex
          lib/test_web/plaid_live.ex
          test/test/integrations/plaid_test.exs
          test/test_web/live/plaid_live_test.exs
        ) do
      assert_creates(igniter, path)
    end
  end

  test "config: the catalog gains Plaid after the webhook connector, runtime.exs reads PLAID_*, the fake serves the tests",
       %{igniter: igniter} do
    assert_has(
      source(igniter, "config/config.exs"),
      "connectors: [Test.Integrations.Connectors.Webhook, Test.Integrations.Connectors.Plaid]"
    )

    runtime = source(igniter, "config/runtime.exs")

    for snippet <- [
          "PLAID_CLIENT_ID",
          "PLAID_ENV",
          "Test.Integrations.Connectors.Plaid.Client.Fake",
          "Test.Integrations.Connectors.Plaid.Client.HTTP"
        ] do
      assert_has(runtime, snippet)
    end
  end

  test "routes /integrations/plaid in the signed-in session, with no navigation entry", %{
    igniter: igniter
  } do
    assert_has(source(igniter, @router), ~s|live "/integrations/plaid", PlaidLive|)
    refute_has(source(igniter, @layouts), ~s|~p"/integrations/plaid"|)
    assert_has(source(igniter, @fixtures), "def plaid_source_fixture(organization, user")
  end

  test "the source resource disconnects before a delete and the form leaves Plaid out", %{
    igniter: igniter
  } do
    assert_has(source(igniter, @source), "change Test.Integrations.Changes.Disconnect")
    assert_has(source(igniter, @setup_source), "require_setup")
    assert_has(source(igniter, "lib/test_web/integrations_live.ex"), "@addable")
    assert_has(source(igniter, @domain), "{:ok, []} -> {:ok, %{created: 0, duplicates: 0}}")
    refute Enum.any?(igniter.warnings, &(&1 =~ "predates"))
  end

  test "applying twice changes nothing", %{igniter: igniter} do
    again = Saas.apply(igniter, plaid: true)

    for path <- [
          @router,
          @layouts,
          @endpoint_path,
          "config/config.exs",
          "config/runtime.exs",
          @fixtures,
          @source,
          @setup_source,
          @domain,
          @connector_behaviour
        ] do
      assert source(again, path) == source(igniter, path), "#{path} changed on the second run"
    end
  end

  test "is opt-in" do
    igniter = Saas.apply(saas_project(), integrations: true)

    refute_creates(igniter, @connector)
    refute_has(source(igniter, "config/config.exs"), "Connectors.Plaid")
    refute_has(source(igniter, "config/runtime.exs"), "PLAID_")
  end

  describe "mix tinderbox.gen.plaid" do
    test "refuses a project that is not a SaaS project" do
      assert_raise Mix.Error, ~r/--stack saas/, fn ->
        Igniter.compose_task(saas_project(), Mix.Tasks.Tinderbox.Gen.Plaid, [])
      end
    end

    test "refuses a project that has it", %{igniter: igniter} do
      assert_raise Mix.Error, ~r/already exists: this project has Plaid/, fn ->
        Igniter.compose_task(igniter, Mix.Tasks.Tinderbox.Gen.Plaid, [])
      end
    end

    test "refuses a project without the vault" do
      organization = "defmodule TestWeb.LiveOrganization do\nend\n"
      project = saas_project(files: [{"lib/test_web/live_organization.ex", organization}])

      assert_raise Mix.Error, ~r/Test.Vault is missing/, fn ->
        Igniter.compose_task(project, Mix.Tasks.Tinderbox.Gen.Plaid, [])
      end
    end

    test "refuses an app.js without colocated hooks" do
      project =
        Saas.apply(saas_project(), integrations: true)
        |> rewrite("assets/js/app.js", &String.replace(&1, "colocatedHooks", "otherHooks"))

      assert_raise Mix.Error, ~r/does not register colocated hooks/, fn ->
        Igniter.compose_task(project, Mix.Tasks.Tinderbox.Gen.Plaid, [])
      end
    end

    test "on a project with integrations, adds only Plaid and no migration" do
      with_integrations = Saas.apply(saas_project(), integrations: true)
      igniter = Igniter.compose_task(with_integrations, Mix.Tasks.Tinderbox.Gen.Plaid, [])

      assert_creates(igniter, @connector)
      assert codegens(igniter) == codegens(with_integrations)

      for path <- [@source, @setup_source, @domain, @connector_behaviour] do
        assert source(igniter, path) == source(with_integrations, path), "#{path} changed"
      end

      assert_has_notice(igniter, &(&1 =~ "Plaid added"))
      refute Enum.any?(igniter.warnings, &(&1 =~ "predates"))
      refute Enum.any?(igniter.warnings, &(&1 =~ "stores the cursor after the records"))
    end

    test "on a project without integrations, adds all three blocks with one migration" do
      igniter =
        saas_project()
        |> Saas.apply([])
        |> Igniter.compose_task(Mix.Tasks.Tinderbox.Gen.Plaid, [])

      assert_creates(igniter, "lib/test/file_drop.ex")
      assert_creates(igniter, "lib/test/integrations.ex")
      assert_creates(igniter, @connector)
      assert codegen?(igniter, "add_integrations")
      assert_has_notice(igniter, &(&1 =~ "File drop added"))
      assert_has_notice(igniter, &(&1 =~ "Integrations added"))
      assert_has_notice(igniter, &(&1 =~ "Plaid added"))
    end

    test "a project whose integrations predate setup pages gets the callbacks, the destroy change, the form guard and quiet deliveries, and a warning about the cursor" do
      old =
        saas_project()
        |> Saas.apply(integrations: true)
        |> rewrite(
          @source,
          &Regex.replace(
            ~r/^[ \t]*change[ (]Test\.Integrations\.Changes\.Disconnect\)?\n/m,
            &1,
            ""
          )
        )
        |> rewrite(@setup_source, fn content ->
          content = Regex.replace(~r/^[ \t]*\|> require_setup\(connector\)\n/m, content, "")
          Regex.replace(~r/\n  # A connector set up on its own page.*?\n  end\n/s, content, "\n")
        end)
        |> rewrite(@domain, fn content ->
          Regex.replace(~r/^.*# Not a delivery.*\n.*\{:ok, \[\]\} ->.*\n/m, content, "")
        end)
        |> rewrite(@connector_behaviour, fn content ->
          content =
            Regex.replace(
              ~r/\n[ \t]*@doc "Where a source of this connector.*?@callback disconnect[^\n]*\n/s,
              content,
              "\n"
            )

          Regex.replace(~r/,\s*setup_path: 0,\s*disconnect: 1/, content, "")
        end)
        # Only inspected, never parsed.
        |> rewrite(
          "lib/test_web/integrations_live.ex",
          &Regex.replace(~r/^.*setup_path.*\n/m, &1, "")
        )
        |> rewrite(
          "lib/test/integrations/changes/sync.ex",
          &String.replace(&1, "ingest(source, records, cursor)", "ingest(source, records)")
        )
        |> Igniter.rm("lib/test/integrations/changes/disconnect.ex")

      refute_has(source(old, @source), "Changes.Disconnect")
      refute_has(source(old, @setup_source), "require_setup")
      refute_has(source(old, @domain), "{:ok, []}")
      refute_has(source(old, @connector_behaviour), "@callback setup_path")
      refute_has(source(old, @connector_behaviour), "setup_path: 0")

      igniter = Igniter.compose_task(old, Mix.Tasks.Tinderbox.Gen.Plaid, [])

      behaviour = source(igniter, @connector_behaviour)
      assert_has(behaviour, "@callback setup_path() :: String.t()")
      assert_has(behaviour, "@callback disconnect(source :: map()) :: :ok | {:error, term()}")
      assert_has(behaviour, "@optional_callbacks setup_path: 0, disconnect: 1")

      source = source(igniter, @source)
      assert_has(source, "change Test.Integrations.Changes.Disconnect")
      assert order(source, "destroy :destroy do") < order(source, "Changes.Disconnect")
      assert order(source, "Changes.Disconnect") < order(source, "policies do")

      setup_source = source(igniter, @setup_source)
      assert_has(setup_source, "|> require_setup(connector)")
      assert_has(setup_source, "defp require_setup(")

      domain = source(igniter, @domain)
      quiet = "{:ok, []} -> {:ok, %{created: 0, duplicates: 0}}"
      assert order(domain, quiet) < order(domain, "{:ok, records} -> ingest(source, records)")

      assert_creates(igniter, "lib/test/integrations/changes/disconnect.ex")

      assert [_warning] =
               Enum.filter(igniter.warnings, &(&1 =~ ~r/predates connector setup pages/))

      assert [_warning] =
               Enum.filter(igniter.warnings, &(&1 =~ ~r/stores the cursor after the records/))

      refute Enum.any?(igniter.warnings, &(&1 =~ ~r/Could not/))
    end
  end

  defp rewrite(igniter, path, fun) do
    igniter = Igniter.include_existing_file(igniter, path)

    Igniter.update_file(igniter, path, fn source ->
      Rewrite.Source.update(source, :content, fun.(Rewrite.Source.get(source, :content)))
    end)
  end

  defp codegen?(igniter, name) do
    Enum.any?(igniter.tasks, fn
      {"ash.codegen", [codegen | _]} -> codegen =~ name
      _task -> false
    end)
  end

  defp codegens(igniter), do: for({"ash.codegen", args} <- igniter.tasks, do: args)
end
