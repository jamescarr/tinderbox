defmodule Tinderbox.Test.SaasFixtures do
  @moduledoc """
  The project the SaaS generator runs against: `phx.new` plus the output of
  `ash.install`, `ash_postgres.install`, `ash_json_api.install`, `ash_phoenix.install`,
  `ash_authentication.install` (no strategy yet), `ash_authentication_phoenix.install`,
  `oban.install` and `ash_oban.install`, with the app renamed to `:test`.

  `Test.Accounts.UserIdentity` is part of the fixtures although the generator
  creates it in a real project: `ash.gen.resource` + `ash.extend` install Ash's
  policy authorizer, which fetches dependencies, and Igniter refuses that in test
  mode. A project that has the resource already is the other path
  `AshAuthentication.Igniter.ensure_user_identity_resource/3` takes.

  The files under `test/fixtures/saas` are copies of what those installers wrote
  in a real generated project, so the generator is tested against the shape it
  has to edit rather than against a hand-written approximation. Refresh them by
  generating a project and copying the files over (`saas_demo` becomes `test`).
  """

  import Igniter.Test

  @root Path.expand("../fixtures/saas", __DIR__)

  @pattern Path.join(@root, "**/*.fixture")

  @paths @pattern
         |> Path.wildcard()
         |> Enum.map(&Path.relative_to(&1, @root))
         |> Enum.sort()

  for path <- @paths, do: @external_resource(Path.join(@root, path))

  @files Map.new(@paths, fn path ->
           {String.replace_suffix(path, ".fixture", ""), File.read!(Path.join(@root, path))}
         end)

  # `@external_resource` only notices a fixture that changes, not one that is
  # added or removed; this makes Mix recompile the module for those too.
  @doc false
  def __mix_recompile__? do
    @pattern
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.sort() != @paths
  end

  @doc "Project-relative path => content of every fixture file."
  @spec files() :: %{Path.t() => String.t()}
  def files, do: @files

  @doc "A test project holding the files above."
  @spec saas_project(keyword()) :: Igniter.t()
  def saas_project(opts \\ []) do
    test_project(files: Map.merge(@files, Map.new(Keyword.get(opts, :files, []))))
  end
end
