defmodule UpmarketStack.Gen.StorageTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias UpmarketStack.Gen.Storage

  test "adds the ex_aws and Req dependencies" do
    mix_exs = source(Storage.apply(test_project(), []), "mix.exs")

    assert mix_exs =~ ~s({:ex_aws, "~> 2.7"})
    assert mix_exs =~ ~s({:ex_aws_s3, "~> 2.5"})
    assert mix_exs =~ ~s({:req, "~> 0.7"})
    assert mix_exs =~ ~s({:sweet_xml, "~> 0.7"})
  end

  test "creates the Storage module with both backends" do
    igniter = Storage.apply(test_project(), [])

    assert_creates(igniter, "lib/test/storage.ex")

    storage = source(igniter, "lib/test/storage.ex")
    assert storage =~ "defmodule Test.Storage do"
    assert storage =~ "ExAws.S3.put_object(config()[:s3_bucket], key, body)"
    assert storage =~ "ExAws.S3.get_object(config()[:s3_bucket], key)"
    assert storage =~ ~s({:error, {:http_error, 404, _}} -> {:error, :not_found})
    assert storage =~ "Req.post(url"
    assert storage =~ ~s(unknown STORAGE_BACKEND)
  end

  test "creates runtime.exs when the project has none" do
    igniter = Storage.apply(test_project(), [])

    assert_creates(igniter, "config/runtime.exs")

    runtime = source(igniter, "config/runtime.exs")
    assert runtime =~ "import Config"
    assert runtime =~ "config :ex_aws,"
    assert runtime =~ "config :test, :storage,"
  end

  test "appends after the existing runtime config so it applies in every env" do
    existing = """
    import Config

    if config_env() == :prod do
      config :test, TestWeb.Endpoint, server: true
    end
    """

    runtime =
      test_project(files: %{"config/runtime.exs" => existing})
      |> Storage.apply([])
      |> source("config/runtime.exs")

    assert runtime =~ "server: true"
    assert runtime =~ "http_client: ExAws.Request.Req"
    assert runtime =~ "AWS_ENDPOINT_URL"

    # the emulator override must not end up scoped to the prod block
    assert at(runtime, "if config_env() == :prod") < at(runtime, "if endpoint = System.get_env")
  end

  test "configures the endpoint override without a bucket placeholder (path-style)" do
    runtime = source(Storage.apply(test_project(), []), "config/runtime.exs")

    assert runtime =~ ~s(config :ex_aws, :s3, override)
    assert runtime =~ ~s(config :ex_aws, :sqs, override)
    refute runtime =~ "%{bucket}"
  end

  test "the runtime config guard makes re-running a no-op" do
    runtime =
      test_project()
      |> Storage.apply([])
      |> Storage.apply([])
      |> source("config/runtime.exs")

    assert length(String.split(runtime, "http_client: ExAws.Request.Req")) == 2
  end

  defp source(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  defp at(string, substring), do: :binary.match(string, substring) |> elem(0)
end
