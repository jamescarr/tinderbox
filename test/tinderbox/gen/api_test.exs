defmodule Tinderbox.Gen.ApiTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Tinderbox.Gen.Api

  # The router `phx.new --no-html …` generates, after `ash_json_api.install` has
  # mounted its router (and swagger UI) at /api/json.
  @router """
  defmodule TestWeb.Router do
    use TestWeb, :router

    pipeline :api do
      plug :accepts, ["json"]
    end

    scope "/api/json" do
      pipe_through [:api]

      forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
        path: "/api/json/open_api",
        default_model_expand_depth: 4

      forward "/", TestWeb.AshJsonApiRouter
    end

    scope "/api", TestWeb do
      pipe_through :api
    end
  end
  """

  # The test project's formatter has no Phoenix locals, so it may print these
  # macros with or without parentheses; a generated project's does not.
  @forward ~r/forward\(?\s*"\/",\s*TestWeb\.AshJsonApiRouter\s*\)?/

  test "mounts the AshJsonApi router at /api in an alias-free scope" do
    router = mount(1)

    # `scope "/api", TestWeb` would make Phoenix resolve the forward relative to
    # the scope alias: TestWeb.TestWeb.AshJsonApiRouter.
    assert router =~
             ~r/scope "\/api" do\s+pipe_through\(?\[:api\]\)?\s+forward\(?\s*"\/",\s*TestWeb\.AshJsonApiRouter\s*\)?\s+end/
  end

  test "comes after the installer's /api/json scope, so swagger stays reachable" do
    router = mount(1)

    # A `forward "/"` in /api swallows everything under it, including /api/json.
    assert position(router, ~s(scope "/api/json")) < position(router, ~s(scope "/api" do))
  end

  test "re-running leaves the router exactly as it was, not with a second unreachable forward" do
    once = mount(1)
    twice = mount(2)

    # The installer's forward plus ours.
    assert count(once, @forward) == 2
    assert count(twice, @forward) == 2
    assert twice == once
  end

  test "does nothing when the project has no router" do
    igniter = Api.mount_json_api(test_project(), TestWeb.AshJsonApiRouter, nil)

    assert_unchanged(igniter)
  end

  defp mount(times) do
    igniter = test_project(files: %{"lib/test_web/router.ex" => @router})

    1..times
    |> Enum.reduce(igniter, fn _, igniter ->
      Api.mount_json_api(igniter, TestWeb.AshJsonApiRouter, nil)
    end)
    |> Map.fetch!(:rewrite)
    |> Rewrite.source!("lib/test_web/router.ex")
    |> Rewrite.Source.get(:content)
  end

  defp position(string, substring), do: :binary.match(string, substring) |> elem(0)
  defp count(string, regex), do: regex |> Regex.scan(string) |> length()
end
