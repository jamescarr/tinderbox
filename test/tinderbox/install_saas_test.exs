defmodule Tinderbox.InstallSaasTest do
  # The Ash domain list is read from the application env, which is global.
  use ExUnit.Case, async: false

  import Igniter.Test
  import Tinderbox.Test.SaasFixtures
  import Tinderbox.Test.SourceHelpers, only: [source: 2]

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

  test "--themepack reaches the SaaS stack's UI kit" do
    igniter = install(["--stack", "saas", "--themepack", "slate"])

    assert source(igniter, "assets/css/app.css") =~ "/* tinderbox:themepack slate"
  end

  test "deploys to Fly.io by default: the fly files, flyctl and `mise run deploy`", %{
    igniter: igniter
  } do
    assert_creates(igniter, "fly.toml")
    assert_creates(igniter, "fly/nats/fly.toml")
    assert source(igniter, ".mise.toml") =~ "[tasks.deploy]"
  end

  test "--deploy none leaves Fly.io out of the files, mise and the README" do
    igniter = install(["--stack", "saas", "--deploy", "none"])

    refute_creates(igniter, "fly.toml")
    refute_creates(igniter, "fly/nats/fly.toml")
    refute source(igniter, ".mise.toml") =~ "flyctl"
    refute source(igniter, "README.md") =~ "Deploying to Fly.io"
  end

  test "--deploy is ignored by the other stacks" do
    igniter = install(["--stack", "ui", "--deploy", "fly"])

    refute_creates(igniter, "fly.toml")
  end

  test "--stack ui installs only the UI kit, without compose or mise" do
    igniter = install(["--stack", "ui", "--themepack", "harbor"])

    assert_creates(igniter, "lib/test_web/ui/components.ex")
    refute_creates(igniter, "docker-compose.yml")
    refute_creates(igniter, ".mise.toml")
    assert source(igniter, "assets/css/app.css") =~ "/* tinderbox:themepack harbor"
  end

  test "--file-drop adds the file drop, a ClamAV service to start on demand, and its settings" do
    igniter = install(["--stack", "saas", "--file-drop"])

    assert_creates(igniter, "lib/test/file_drop.ex")
    refute_creates(igniter, "lib/test/integrations.ex")
    assert_file_drop_settings(igniter)
  end

  test "--integrations brings the file drop and its settings with it" do
    igniter = install(["--stack", "saas", "--integrations"])

    assert_creates(igniter, "lib/test/integrations.ex")
    assert_creates(igniter, "lib/test/file_drop.ex")
    assert_file_drop_settings(igniter)
  end

  test "--plaid brings integrations, the file drop and the Plaid settings" do
    igniter = install(["--stack", "saas", "--plaid"])

    assert_creates(igniter, "lib/test/integrations/connectors/plaid.ex")
    assert_creates(igniter, "lib/test/integrations.ex")
    assert_creates(igniter, "lib/test/file_drop.ex")
    assert_file_drop_settings(igniter)

    assert source(igniter, ".env.example") =~ "export PLAID_ENV=sandbox\n"
    assert source(igniter, ".mise.toml") =~ ~s(PLAID_ENV = "sandbox"\n)
    assert source(igniter, ".mise.toml") =~ ~s(PLAID_SECRET = "replace_me")

    fly = source(igniter, "fly.toml")
    assert fly =~ ~s(  PLAID_ENV = "sandbox"\n)
    # In the secrets comment: the release refuses to boot without them.
    assert fly =~ "SSO_CLIENT_SECRET, PLAID_CLIENT_ID, PLAID_SECRET and the STRIPE_* keys"

    refute source(igniter, "docker-compose.yml") =~ "plaid"
  end

  test "without any of the flags there is no file drop, ClamAV, scanner or Plaid setting", %{
    igniter: igniter
  } do
    refute_creates(igniter, "lib/test/file_drop.ex")
    refute source(igniter, "docker-compose.yml") =~ "clamav"
    refute source(igniter, ".env.example") =~ "FILE_DROP_SCANNER"
    refute source(igniter, ".mise.toml") =~ "FILE_DROP_SCANNER"
    refute source(igniter, "fly.toml") =~ "FILE_DROP_SCANNER"
    refute source(igniter, ".env.example") =~ "PLAID_ENV"
    refute source(igniter, ".mise.toml") =~ "PLAID_ENV"
    refute source(igniter, "fly.toml") =~ "PLAID_"
    refute_creates(igniter, "lib/test/integrations/connectors/plaid.ex")
  end

  defp assert_file_drop_settings(igniter) do
    compose = source(igniter, "docker-compose.yml")

    assert compose =~ "  clamav:\n    image: clamav/clamav-debian:1.5\n    profiles: [\"scan\"]"
    assert compose =~ ~s|"${CLAMAV_PORT:-3310}:3310"|
    assert compose =~ "\n  clamav-data:\n"

    # Not started by `docker compose up`, so `ready` does not wait for it.
    [_services, ready] = String.split(compose, "  ready:", parts: 2)
    refute ready =~ "clamav:"

    assert source(igniter, ".env.example") =~ "export FILE_DROP_SCANNER=none\n"
    assert source(igniter, ".mise.toml") =~ ~s(FILE_DROP_SCANNER = "none"\n)
    # The release refuses to boot without it.
    assert source(igniter, "fly.toml") =~ ~s(  FILE_DROP_SCANNER = "none"\n)
  end

  defp install(argv) do
    Igniter.compose_task(saas_project(), "tinderbox.install", argv)
  end
end
