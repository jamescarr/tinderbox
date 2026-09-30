defmodule Tinderbox.Env do
  @moduledoc """
  The environment a generated project runs with locally.

  One list of `{title, [{name, value}]}` sections, rendered twice: as
  `.env.example` (every line `export`ed, so a plain `source` reaches child
  processes — a bare `KEY=value` would only set shell variables) and as the
  `[env]` table of `.mise.toml`. Rendering both from the same data is what keeps
  them from drifting.
  """

  alias Tinderbox.Broker

  @type section :: {title :: String.t(), [{name :: String.t(), value :: String.t()}]}

  # Values land unquoted in a shell file and inside a TOML basic string. Anything
  # outside this set would need escaping in one of them, so refuse it instead of
  # emitting two files that disagree about what a value is.
  @safe_value ~r/\A[A-Za-z0-9_.\/:@%+,=-]*\z/

  @doc """
  The env sections for a generated project.

  Options: `:app`, `:module` (base module, used in a comment), `:broker`, and
  optionally `:stack` (`"api"` | `"worker"`, default `"api"`) and `:db?`
  (default `true`).
  """
  @spec sections(keyword()) :: [section()]
  def sections(opts) do
    app = Keyword.fetch!(opts, :app)
    module = Keyword.fetch!(opts, :module)
    broker = Keyword.fetch!(opts, :broker)
    stack = Keyword.get(opts, :stack, "api")
    db? = Keyword.get(opts, :db?, true)
    app_dash = Broker.app_dash(app)

    postgres =
      if db? do
        [
          {"Postgres (MIX_ENV=prod runs; dev and test read config/dev.exs and config/test.exs)",
           [
             {"DATABASE_URL", "ecto://postgres:postgres@localhost:5432/#{app}_dev"},
             {"POOL_SIZE", "10"}
           ]}
        ]
      else
        []
      end

    shared = [
      {"Floci (AWS emulator): S3 + SQS",
       [
         {"AWS_ENDPOINT_URL", "http://localhost:4566"},
         {"AWS_REGION", "us-east-1"},
         {"AWS_DEFAULT_REGION", "us-east-1"},
         {"AWS_ACCESS_KEY_ID", "test"},
         {"AWS_SECRET_ACCESS_KEY", "test"},
         {"S3_BUCKET", "#{app_dash}-local"}
       ]},
      {"floci-gcp (GCP emulator): GCS + Pub/Sub",
       [
         {"STORAGE_EMULATOR_HOST", "http://localhost:4588"},
         {"GCP_PROJECT_ID", "floci-local"},
         {"GCS_BUCKET", "#{app_dash}-local"}
       ]},
      {"Object storage backend used by #{inspect(module)}.Storage: s3 | gcs",
       [{"STORAGE_BACKEND", "s3"}]}
    ]

    worker =
      if stack == "worker" do
        [{"Worker", [{"HEALTH_PORT", "4001"} | Broker.env_vars(broker, app_dash)]}]
      else
        []
      end

    (postgres ++ shared ++ worker)
    |> drop_repeated_names()
    |> validate!()
  end

  @doc """
  Renders sections as `.env.example`: every assignment is an `export`.
  """
  @spec dotenv([section()]) :: String.t()
  def dotenv(sections) do
    header = """
    # Local development environment. Load it into the current shell with
    #   cp .env.example .env && . ./.env
    # (every line is exported, so no `set -a` is needed).

    """

    header <> render(sections, fn name, value -> "export #{name}=#{value}" end)
  end

  @doc """
  Renders sections as the body of the `[env]` table in `.mise.toml`.
  """
  @spec toml([section()]) :: String.t()
  def toml(sections) do
    render(sections, fn name, value -> ~s(#{name} = "#{value}") end)
  end

  @doc false
  @spec validate!([section()]) :: [section()]
  def validate!(sections) do
    for {_title, vars} <- sections, {name, value} <- vars do
      unless String.match?(value, @safe_value) do
        raise ArgumentError,
              "env value for #{name} (#{inspect(value)}) needs quoting, which " <>
                "Tinderbox.Env does not do; restrict it to #{inspect(@safe_value)}"
      end
    end

    sections
  end

  defp render(sections, line) do
    Enum.map_join(sections, "\n", fn {title, vars} ->
      "# #{title}\n" <>
        Enum.map_join(vars, "", fn {name, value} -> line.(name, value) <> "\n" end)
    end)
  end

  # A duplicate key is a parse error in TOML (and a silent override in a shell
  # file), and some brokers share a variable with the emulator block
  # (`GCP_PROJECT_ID` is both the floci-gcp project and the Pub/Sub project).
  # The first occurrence wins; sections left empty disappear.
  defp drop_repeated_names(sections) do
    {kept, _seen} =
      Enum.map_reduce(sections, MapSet.new(), fn {title, vars}, seen ->
        fresh = Enum.reject(vars, fn {name, _value} -> MapSet.member?(seen, name) end)
        {{title, fresh}, Enum.reduce(fresh, seen, fn {name, _}, acc -> MapSet.put(acc, name) end)}
      end)

    Enum.reject(kept, fn {_title, vars} -> vars == [] end)
  end
end
