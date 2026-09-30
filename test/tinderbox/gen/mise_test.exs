defmodule Tinderbox.Gen.MiseTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Tinderbox.Gen.Compose
  alias Tinderbox.Gen.Mise
  alias Tinderbox.Toolchain

  # What the generator would see on a newer release, and on a dev build.
  @newer %{elixir: "1.21.0", otp_release: "30", otp_version: "30.0"}
  @dev %{elixir: "1.21.0-dev", otp_release: "30", otp_version: nil}

  test "creates .mise.toml" do
    assert_creates(mise(), ".mise.toml")
  end

  # A dev build of Elixir has no mise version, so it is covered by the fallback
  # tests below instead.
  if Version.parse!(System.version()).pre == [] do
    test "[tools] pins the Elixir and OTP that are running the generator" do
      toml = content(mise())

      otp_version_file =
        Path.join([to_string(:code.root_dir()), "releases", System.otp_release(), "OTP_VERSION"])

      erlang =
        case File.read(otp_version_file) do
          {:ok, version} -> String.trim(version)
          {:error, _reason} -> System.otp_release()
        end

      assert pin(toml, "elixir") == "#{System.version()}-otp-#{System.otp_release()}"
      assert pin(toml, "erlang") == erlang
    end
  end

  test "on a newer Elixir the pin still satisfies the `elixir:` requirement mix.exs was written with" do
    # `mix new` writes `~> <running major.minor>`; a hard-coded pin only satisfies
    # that on the release it happens to name.
    mix_exs = """
    defmodule Test.MixProject do
      use Mix.Project

      def project do
        [app: :test, version: "0.1.0", elixir: "~> 1.21", deps: []]
      end
    end
    """

    igniter = Mise.apply(test_project(files: %{"mix.exs" => mix_exs}), vm: @newer)
    toml = content(igniter)

    [requirement] = Regex.run(~r/elixir: "([^"]+)"/, mix_exs, capture: :all_but_first)
    [version, otp] = toml |> pin("elixir") |> String.split("-otp-")

    assert Version.match?(version, requirement)
    assert otp == "30"
    assert pin(toml, "erlang") == "30.0"
    refute Enum.any?(igniter.notices, &(&1 =~ "pre-release"))
  end

  test "a dev or pre-release Elixir falls back to one consistent pair, and the notice names it" do
    igniter = mise(vm: @dev)
    toml = content(igniter)

    # Elixir's `-otp-N` and Erlang's major have to agree or mise cannot build it.
    [_version, otp] = toml |> pin("elixir") |> String.split("-otp-")
    assert toml |> pin("erlang") |> String.split(".") |> hd() == otp

    assert_has_notice(igniter, &(&1 =~ "Elixir 1.21.0-dev is a dev or pre-release build"))
    assert_has_notice(igniter, &(&1 =~ pin(toml, "elixir")))
    assert_has_notice(igniter, &(&1 =~ pin(toml, "erlang")))
  end

  test "CMake is pinned for the Kafka worker only (brod builds a NIF from source)" do
    assert content(mise(stack: "worker", broker: :kafka)) =~
             ~s(cmake = "#{Toolchain.cmake()}")

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

  # The version pinned for `tool` under `[tools]`.
  defp pin(toml, tool) do
    [version] = Regex.run(~r/^#{tool} = "([^"]+)"$/m, toml, capture: :all_but_first)
    version
  end

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
