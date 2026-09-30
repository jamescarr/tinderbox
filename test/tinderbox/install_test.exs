defmodule Tinderbox.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # `mix tinderbox.install` is the entry point igniter runs. Composing it here runs
  # the real task against a test project: flag parsing, the flags it forwards to
  # the stack generator, and which files and notices come out. (What a test
  # project cannot do is fetch the packages the tasks declare in `installs:`.)

  test "a worker gets the stack, docker compose, mise, and a mise-first notice" do
    igniter = install(["--stack", "worker", "--broker", "sqs"])

    assert_creates(igniter, "lib/test/pipeline.ex")
    assert_creates(igniter, "docker-compose.yml")
    assert_creates(igniter, ".env.example")
    assert_creates(igniter, ".mise.toml")

    assert_has_notice(igniter, &(&1 =~ "mise trust && mise run dev"))
    assert_has_notice(igniter, &(&1 =~ "starts the services, sets up the database"))
  end

  test "--no-mise skips .mise.toml and the notice falls back to docker compose" do
    igniter = install(["--stack", "worker", "--no-mise"])

    refute_creates(igniter, ".mise.toml")
    assert_creates(igniter, "docker-compose.yml")

    assert_has_notice(igniter, &(&1 =~ "docker compose up -d --wait"))
    assert_has_notice(igniter, &(&1 =~ ". ./.env && mix ash.setup && mix run --no-halt"))
    refute Enum.any?(igniter.notices, &(&1 =~ "mise trust"))
  end

  test "--no-compose skips the compose file and .env.example, and mise drops up/down" do
    igniter = install(["--stack", "worker", "--no-compose"])

    refute_creates(igniter, "docker-compose.yml")
    refute_creates(igniter, ".env.example")
    assert_creates(igniter, ".mise.toml")

    toml = source(igniter, ".mise.toml")
    refute toml =~ "[tasks.up]"
    refute toml =~ ~s(depends = ["up"])

    assert_has_notice(igniter, &(&1 =~ "sets up the database"))
    refute Enum.any?(igniter.notices, &(&1 =~ "starts the services"))
  end

  test "--no-mise --no-compose leaves only the stack, and the notice says so" do
    igniter = install(["--stack", "worker", "--no-mise", "--no-compose"])

    refute_creates(igniter, ".mise.toml")
    refute_creates(igniter, "docker-compose.yml")

    assert_has_notice(igniter, &(&1 == "Next: mix ash.setup && mix run --no-halt"))
  end

  test "the Kafka worker's mise config pins cmake and its notice warns about it" do
    igniter = install(["--stack", "worker", "--broker", "kafka"])

    assert source(igniter, ".mise.toml") =~ "cmake"
    assert_has_notice(igniter, &(&1 =~ "CMake"))
  end

  test "an unknown --stack is refused" do
    assert_raise Mix.Error, ~r/Unknown --stack "cloud"/, fn ->
      install(["--stack", "cloud"])
    end
  end

  defp install(argv) do
    Igniter.compose_task(test_project(), "tinderbox.install", argv)
  end

  defp source(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end
end
