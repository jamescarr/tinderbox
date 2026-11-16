defmodule Tinderbox.Gen.SaasFileDropTest do
  # The Ash domain list is read from the application env, which is global.
  use ExUnit.Case, async: false

  import Igniter.Test
  import Tinderbox.Test.SaasFixtures
  import Tinderbox.Test.SourceHelpers

  alias Tinderbox.Gen.Saas

  @router "lib/test_web/router.ex"
  @layouts "lib/test_web/components/layouts.ex"
  @fixtures "test/support/fixtures.ex"

  setup_all do
    Application.put_env(:test, :ash_domains, [Test.Accounts])
    on_exit(fn -> Application.delete_env(:test, :ash_domains) end)

    {:ok, igniter: Saas.apply(saas_project(), file_drop: true)}
  end

  test "creates the domain, the upload, the scanner, the pages and the tests", %{
    igniter: igniter
  } do
    for path <- ~w(
          lib/test/file_drop.ex
          lib/test/file_drop/upload.ex
          lib/test/file_drop/sniff.ex
          lib/test/file_drop/scanner.ex
          lib/test/file_drop/scanners/clam_av.ex
          lib/test/file_drop/handler.ex
          lib/test/file_drop/handlers/keep.ex
          lib/test/file_drop/changes/ingest.ex
          lib/test/file_drop/changes/delete_object.ex
          lib/test/file_drop/changes/broadcast.ex
          lib/test_web/file_drop_live.ex
          lib/test_web/file_drop_controller.ex
          test/test/file_drop_test.exs
          test/test/file_drop/clam_av_test.exs
          test/test_web/live/file_drop_live_test.exs
          test/test_web/controllers/file_drop_controller_test.exs
        ) do
      assert_creates(igniter, path)
    end

    refute_creates(igniter, "lib/test/integrations.ex")

    upload = source(igniter, "lib/test/file_drop/upload.ex")
    assert_has(upload, "mixin Test.Accounts.VersionIndexes")
    assert_has(upload, "ignore_actions [:ingest, :mark_failed]")
  end

  test "routes /drop in the signed-in session, and the download once", %{igniter: igniter} do
    router = source(igniter, @router)

    live = ~s|live "/drop", FileDropLive|
    session = "ash_authentication_live_session :authenticated_routes"
    [_before, after_session] = router |> plain() |> String.split(plain(session), parts: 2)
    [inside, _rest] = String.split(after_session, " end ", parts: 2)
    assert inside =~ plain(live)

    download = ~s|get "/drop/:id/download", FileDropController, :download|
    assert length(String.split(plain(router), plain(download))) == 2
  end

  test "the navigation has Files before the Platform section", %{igniter: igniter} do
    layouts = source(igniter, @layouts)

    assert_has(layouts, ~s|navigate={~p"/drop"}|)

    assert order(layouts, ~s|~p"/drop"|) <
             order(layouts, ~s|<.nav_section :if={@current_user.role == :admin}|)
  end

  test "config: the domain, its queue, the handler and the extensions", %{igniter: igniter} do
    config = source(igniter, "config/config.exs")

    assert_has(config, "Test.FileDrop,")
    assert_has(config, "file_drop: 2")
    assert_has(config, "handler: Test.FileDrop.Handlers.Keep")
    assert_has(config, ~s|extensions: [".csv", ".ofx", ".qfx", ".pdf", ".zip", ".eml", ".txt"]|)

    runtime = source(igniter, "config/runtime.exs")

    assert_has(runtime, ~s|System.get_env("FILE_DROP_SCANNER")|)
    assert_has(runtime, ~s|raise "environment variable FILE_DROP_SCANNER is missing|)
    assert_has(runtime, ~s|System.get_env("CLAMAV_PORT", "3310")|)

    assert_has(
      source(igniter, @fixtures),
      "def upload_fixture(organization, user, attrs \\\\ %{})"
    )
  end

  test "applying twice changes nothing", %{igniter: igniter} do
    again = Saas.apply(igniter, file_drop: true)

    for path <- [@router, @layouts, "config/config.exs", "config/runtime.exs", @fixtures] do
      assert source(again, path) == source(igniter, path), "#{path} changed on the second run"
    end
  end

  test "is opt-in" do
    igniter = Saas.apply(saas_project(), [])

    refute_creates(igniter, "lib/test/file_drop.ex")
    refute_has(source(igniter, @router), "FileDropLive")
    refute_has(source(igniter, "config/runtime.exs"), "FILE_DROP_SCANNER")
  end

  describe "mix tinderbox.gen.file_drop" do
    test "refuses a project that is not a SaaS project" do
      assert_raise Mix.Error, ~r/--stack saas/, fn ->
        Igniter.compose_task(saas_project(), Mix.Tasks.Tinderbox.Gen.FileDrop, [])
      end
    end

    test "refuses a project that has it", %{igniter: igniter} do
      assert_raise Mix.Error, ~r/already exists: this project has the file drop/, fn ->
        Igniter.compose_task(igniter, Mix.Tasks.Tinderbox.Gen.FileDrop, [])
      end
    end

    test "adds it to a SaaS project generated without it, with its own migration" do
      igniter =
        saas_project()
        |> Saas.apply([])
        |> Igniter.compose_task(Mix.Tasks.Tinderbox.Gen.FileDrop, [])

      assert_creates(igniter, "lib/test/file_drop/upload.ex")
      assert_has(source(igniter, @router), ~s|live "/drop", FileDropLive|)

      assert Enum.any?(igniter.tasks, fn
               {"ash.codegen", [name | _]} -> name =~ "add_file_drop"
               _task -> false
             end)

      assert {"format", ["priv/repo/migrations/*add_file_drop.exs"]} in igniter.tasks
      assert_has_notice(igniter, &(&1 =~ "FILE_DROP_SCANNER"))
    end
  end
end
