defmodule Tinderbox.Test.SourceHelpers do
  @moduledoc """
  Reading and asserting on the sources a generator left on the igniter.

  A project's formatter (`import_deps`) strips the parentheses Igniter's own
  formatting puts around DSL calls; these tests run without it, so sources and
  expectations are compared with parentheses removed.
  """

  import ExUnit.Assertions

  def source(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  def plain(string) when is_binary(string) do
    string |> String.replace(["(", ")"], " ") |> String.replace(~r/\s+/, " ")
  end

  def assert_has(source, snippet) do
    assert plain(source) =~ plain(snippet), "expected #{inspect(snippet)} in:\n#{source}"
  end

  def refute_has(source, snippet) do
    refute plain(source) =~ plain(snippet), "did not expect #{inspect(snippet)} in:\n#{source}"
  end

  def order(string, substring) do
    case :binary.match(plain(string), plain(substring)) do
      {index, _length} -> index
      :nomatch -> flunk("expected #{inspect(substring)} in:\n#{string}")
    end
  end
end
