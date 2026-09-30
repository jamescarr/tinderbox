defmodule Tinderbox.EnvTest do
  use ExUnit.Case, async: true

  alias Tinderbox.Env

  @brokers [:sqs, :pubsub, :rabbitmq, :kafka]
  @stacks ["api", "worker"]

  test "no variable is defined twice, for every stack, broker and db choice" do
    for stack <- @stacks, broker <- @brokers, db? <- [true, false] do
      names = names(sections(stack: stack, broker: broker, db?: db?))

      assert names == Enum.uniq(names),
             "#{stack}/#{broker}/db=#{db?} repeats #{inspect(names -- Enum.uniq(names))}"
    end
  end

  test "the pubsub worker keeps one GCP_PROJECT_ID although both emulator blocks define it" do
    # A repeated key is a parse error in `.mise.toml`.
    names = names(sections(stack: "worker", broker: :pubsub))

    assert Enum.count(names, &(&1 == "GCP_PROJECT_ID")) == 1
    assert "PUBSUB_SUBSCRIPTION" in names
  end

  test "the worker adds the health port and its broker block; the api does not" do
    worker = names(sections(stack: "worker", broker: :kafka))
    assert "HEALTH_PORT" in worker
    assert "KAFKA_BROKERS" in worker

    api = names(sections(stack: "api", broker: :kafka))
    refute "HEALTH_PORT" in api
    refute "KAFKA_BROKERS" in api
  end

  test "db?: false leaves out the Postgres variables" do
    assert "DATABASE_URL" in names(sections())
    refute "DATABASE_URL" in names(sections(db?: false))
    refute "POOL_SIZE" in names(sections(db?: false))
  end

  test "dotenv/1 exports every assignment" do
    assignments =
      sections(stack: "worker")
      |> Env.dotenv()
      |> String.split("\n")
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    assert assignments != []

    for line <- assignments do
      assert String.starts_with?(line, "export "), "not exported: #{line}"
    end
  end

  @tag :tmp_dir
  test "sourcing the rendered .env.example puts every variable in a child process's environment",
       %{tmp_dir: tmp_dir} do
    sections = sections(stack: "worker", broker: :pubsub)
    path = Path.join(tmp_dir, ".env")
    File.write!(path, Env.dotenv(sections))

    # A plain `source`, as the docs say. Bare `KEY=value` lines would only set
    # shell variables, and `env` (a child process) would not list them.
    {output, 0} = System.cmd("bash", ["-c", ~s(. "$1" && env), "bash", path])

    exported =
      for line <- String.split(output, "\n"),
          [key, value] <- [String.split(line, "=", parts: 2)],
          into: %{} do
        {key, value}
      end

    for {_title, vars} <- sections, {name, value} <- vars do
      assert exported[name] == value, "#{name} did not reach the child process"
    end
  end

  test "dotenv/1 and toml/1 render the same variables" do
    for stack <- @stacks, broker <- @brokers do
      sections = sections(stack: stack, broker: broker)

      from_dotenv =
        ~r/^export ([A-Z_0-9]+)=(.*)$/m
        |> Regex.scan(Env.dotenv(sections))
        |> Map.new(fn [_line, name, value] -> {name, value} end)

      from_toml =
        ~r/^([A-Z_0-9]+) = "(.*)"$/m
        |> Regex.scan(Env.toml(sections))
        |> Map.new(fn [_line, name, value] -> {name, value} end)

      assert from_dotenv == from_toml
      assert map_size(from_dotenv) == length(names(sections))
    end
  end

  test "refuses a value that would need quoting instead of emitting it" do
    assert_raise ArgumentError, ~r/BAD.*needs quoting/, fn ->
      Env.validate!([{"title", [{"BAD", "has a space"}]}])
    end

    assert_raise ArgumentError, ~r/needs quoting/, fn ->
      Env.validate!([{"title", [{"BAD", ~s(say "hi")}]}])
    end
  end

  defp sections(opts \\ []) do
    [app: :demo_worker, module: DemoWorker, broker: :sqs]
    |> Keyword.merge(opts)
    |> Env.sections()
  end

  defp names(sections), do: for({_title, vars} <- sections, {name, _value} <- vars, do: name)
end
