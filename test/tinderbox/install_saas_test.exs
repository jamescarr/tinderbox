defmodule Tinderbox.InstallSaasTest do
  # The Ash domain list is read from the application env, which is global.
  use ExUnit.Case, async: false

  import Igniter.Test
  import Tinderbox.Test.SaasFixtures

  # `mix tinderbox.install --stack saas` against a project holding what the Phoenix
  # and Ash installers write; see `test/tinderbox/install_test.exs` for the other stacks.

  setup do
    Application.put_env(:test, :ash_domains, [Test.Accounts])
    on_exit(fn -> Application.delete_env(:test, :ash_domains) end)

    {:ok, igniter: install(["--stack", "saas"])}
  end

  test "a saas project gets the stack, compose, mise and the local identity provider", %{
    igniter: igniter
  } do
    assert_creates(igniter, "lib/test/accounts/organization.ex")
    assert_creates(igniter, "docker-compose.yml")
    assert_creates(igniter, "docker/dex/config.yaml")
    assert_creates(igniter, ".env.example")
    assert_creates(igniter, ".mise.toml")

    assert_has_notice(igniter, &(&1 =~ "mise trust && mise run dev"))
    assert_has_notice(igniter, &(&1 =~ "mise run stripe"))
  end

  test "its event bus is NATS whatever --broker says, and the application owns the stream", %{
    igniter: igniter
  } do
    compose = source(igniter, "docker-compose.yml")

    assert compose =~ "dex:"
    assert compose =~ "mailpit:"
    assert compose =~ "nats:"
    refute compose =~ "nats-bootstrap:"

    env = source(igniter, ".env.example")

    assert env =~ "export SSO_BASE_URL=http://localhost:5556/dex"
    assert env =~ "export NATS_HOST=localhost"
    refute env =~ "NATS_STREAM"
    refute env =~ "SQS_QUEUE_URL"

    mise = source(igniter, ".mise.toml")

    assert mise =~ "[tasks.stripe]"
    assert mise =~ ~s(run = "mix phx.server")
  end

  test "--no-compose leaves no Dex or Mailpit, and the notice does not promise them" do
    igniter = install(["--stack", "saas", "--no-compose"])

    refute_creates(igniter, "docker-compose.yml")
    refute_creates(igniter, "docker/dex/config.yaml")
    refute Enum.any?(igniter.notices, &(&1 =~ "Mailpit"))
    assert_has_notice(igniter, &(&1 =~ "mise run dev"))
  end

  test "--no-mise falls back to compose and .env, with the Stripe key in .env" do
    igniter = install(["--stack", "saas", "--no-mise"])

    refute_creates(igniter, ".mise.toml")
    assert_has_notice(igniter, &(&1 =~ "docker compose up -d --wait"))

    assert_has_notice(
      igniter,
      &(&1 =~ "STRIPE_SECRET_KEY, STRIPE_PRICE_STARTER, STRIPE_PRICE_PRO in .env")
    )

    refute Enum.any?(igniter.notices, &(&1 =~ "mise run stripe"))
  end

  defp install(argv) do
    Igniter.compose_task(saas_project(), "tinderbox.install", argv)
  end

  defp source(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end
end
