defmodule Tinderbox.Gen.SaasDomainTaskTest do
  # The `mix test.gen.domain` the SaaS generator writes is compiled and run against
  # the fixture project, so what is tested is the task, not its text. The Ash domain
  # list the generator reads is in the application env, which is global.
  use ExUnit.Case, async: false

  import Igniter.Test
  import Tinderbox.Test.SaasFixtures

  setup_all do
    Application.put_env(:test, :ash_domains, [Test.Accounts])
    on_exit(fn -> Application.delete_env(:test, :ash_domains) end)

    Tinderbox.Gen.Saas.apply(saas_project(), [])
    |> source("lib/mix/tasks/test.gen.domain.ex")
    |> Code.compile_string()

    :ok
  end

  test "a new domain is created, registered and gets its queues" do
    igniter =
      gen_domain(saas_project(), ["Test.Upstreams", "--queues", "upstreams:5,dead_letters"])

    assert_creates(igniter, "lib/test/upstreams.ex", fn content ->
      assert content =~ "use Ash.Domain"
    end)

    config = source(igniter, "config/config.exs")

    assert config =~ "ash_domains: [Test.Upstreams, Test.Accounts]"
    assert config =~ "queues: [default: 10, upstreams: 5, dead_letters: 10]"
    assert igniter.issues == []
  end

  test "an existing domain is registered but not recreated, and an existing queue keeps its limit" do
    config =
      String.replace(
        files()["config/config.exs"],
        "ash_domains: [Test.Accounts]",
        "ash_domains: []"
      )

    project = saas_project(files: [{"config/config.exs", config}])

    igniter = gen_domain(project, ["Test.Accounts", "--queues", "default:3"])

    assert source(igniter, "lib/test/accounts.ex") ==
             source(saas_project(), "lib/test/accounts.ex")

    config = source(igniter, "config/config.exs")

    assert config =~ "ash_domains: [Test.Accounts]"
    assert config =~ "queues: [default: 10]"
    refute config =~ "default: 3"
    assert igniter.issues == []
  end

  test "a malformed queue is refused before anything changes" do
    assert_raise Mix.Error, ~r/Invalid --queues entry "upstreams:many"/, fn ->
      gen_domain(saas_project(), ["Test.Upstreams", "--queues", "upstreams:many"])
    end
  end

  test "queues need Oban configured" do
    project = saas_project(files: [{"config/config.exs", "import Config\n"}])

    assert_raise Mix.Error, ~r/--queues needs `config :test, Oban, queues/, fn ->
      gen_domain(project, ["Test.Upstreams", "--queues", "upstreams"])
    end
  end

  # A module, not the task name: `compose_task/3` then only needs it compiled,
  # which the module compiled in memory above is.
  defp gen_domain(project, argv) do
    Igniter.compose_task(project, Mix.Tasks.Test.Gen.Domain, argv)
  end

  defp source(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end
end
