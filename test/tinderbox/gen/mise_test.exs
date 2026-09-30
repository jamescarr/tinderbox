defmodule Tinderbox.Gen.MiseTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Tinderbox.Gen.Compose
  alias Tinderbox.Gen.Mise

  test "creates .mise.toml" do
    assert_creates(mise(), ".mise.toml")
  end

  test "pins the same Elixir and Erlang as this package's own .mise.toml" do
    own = File.read!(Path.expand("../../../.mise.toml", __DIR__))

    assert own =~ ~s(elixir = "#{Mise.versions().elixir}")
    assert own =~ ~s(erlang = "#{Mise.versions().erlang}")
  end

  test "[tools] pins Elixir and Erlang" do
    toml = content(mise())

    assert toml =~ ~s(elixir = "#{Mise.versions().elixir}")
    assert toml =~ ~s(erlang = "#{Mise.versions().erlang}")
  end

  test "CMake is pinned for the Kafka worker only (brod builds a NIF from source)" do
    assert content(mise(stack: "worker", broker: :kafka)) =~
             ~s(cmake = "#{Mise.versions().cmake}")

    for {stack, broker} <- [
          {"worker", :sqs},
          {"worker", :pubsub},
          {"worker", :rabbitmq},
          {"api", :kafka}
        ] do
      refute content(mise(stack: stack, broker: broker)) =~ "cmake",
             "#{stack}/#{broker} should not pin cmake"
    end
  end

  test "[env] carries exactly the variables .env.example does" do
    for {stack, broker} <- [
          {"api", :sqs},
          {"worker", :sqs},
          {"worker", :pubsub},
          {"worker", :kafka}
        ] do
      igniter =
        test_project()
        |> Compose.apply(stack: stack, broker: to_string(broker))
        |> Mise.apply(stack: stack, broker: broker)

      from_dotenv =
        ~r/^export ([A-Z_0-9]+)=(.*)$/m
        |> Regex.scan(content(igniter, ".env.example"))
        |> Map.new(fn [_line, name, value] -> {name, value} end)

      from_toml =
        ~r/^([A-Z_0-9]+) = "(.*)"$/m
        |> Regex.scan(content(igniter))
        |> Map.new(fn [_line, name, value] -> {name, value} end)

      assert from_toml == from_dotenv, "#{stack}/#{broker}: .mise.toml and .env.example disagree"
      assert from_toml["STORAGE_BACKEND"] == "s3"
    end
  end

  test "the API serves with phx.server and has no health task" do
    toml = content(mise(stack: "api"))

    assert toml =~ ~s(run = "mix phx.server")
    refute toml =~ "[tasks.health]"
  end

  test "the worker runs with --no-halt and gets a health task on HEALTH_PORT" do
    toml = content(mise(stack: "worker", broker: :sqs))

    assert toml =~ ~s(run = "mix run --no-halt")
    assert toml =~ "[tasks.health]"
    assert toml =~ "http://localhost:$HEALTH_PORT/health"
    assert toml =~ ~s(HEALTH_PORT = "4001")
  end

  test "`mise run dev` brings everything up: dev -> setup -> up, and test/check need up too" do
    toml = content(mise())

    assert task(toml, "dev") =~ ~s(depends = ["setup"])
    assert task(toml, "setup") =~ ~s(depends = ["up"])
    assert task(toml, "test") =~ ~s(depends = ["up"])
    assert task(toml, "check") =~ ~s(depends = ["up"])
    assert task(toml, "up") =~ ~s(run = "docker compose up -d --wait")
    assert task(toml, "down") =~ ~s(run = "docker compose down")
  end

  test "check is what CI should run" do
    check = task(content(mise()), "check")

    assert check =~ "mix format --check-formatted"
    assert check =~ "mix compile --warnings-as-errors"
    assert check =~ "mix test"
  end

  test "--no-compose leaves out up/down and every dependency on them" do
    toml = content(mise(compose: false))

    refute toml =~ "[tasks.up]"
    refute toml =~ "[tasks.down]"
    refute toml =~ ~s(depends = ["up"])
    assert task(toml, "dev") =~ ~s(depends = ["setup"])
  end

  test "--no-db drops the Postgres variables" do
    refute content(mise(db: false)) =~ "DATABASE_URL"
    assert content(mise()) =~ "DATABASE_URL"
  end

  test "keeps machine-specific overrides out of git" do
    assert content(mise(), ".gitignore") =~ ~r/^\.mise\.local\.toml$/m
  end

  test "ends with a single newline whichever optional blocks are on" do
    for opts <- [[], [stack: "worker"], [compose: false], [stack: "worker", broker: :kafka]] do
      toml = content(mise(opts))

      assert String.ends_with?(toml, "\n")
      refute String.ends_with?(toml, "\n\n")
    end
  end

  test "raises on an unknown broker" do
    assert_raise Mix.Error, ~r/Unknown --broker fog/, fn ->
      Mise.apply(test_project(), stack: "worker", broker: "fog")
    end
  end

  defp mise(opts \\ []), do: Mise.apply(test_project(), opts)

  defp content(igniter, path \\ ".mise.toml") do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  # The text of one `[tasks.<name>]` table, up to the next table.
  defp task(toml, name) do
    [_before, rest] = String.split(toml, "[tasks.#{name}]\n", parts: 2)
    rest |> String.split(~r/^\[/m, parts: 2) |> hd()
  end
end
