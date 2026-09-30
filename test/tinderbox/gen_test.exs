defmodule Tinderbox.GenTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Tinderbox.Gen

  describe "ignore/2" do
    test "appends the lines a .gitignore is missing" do
      gitignore = test_project() |> Gen.ignore([".env", ".mise.local.toml"]) |> gitignore()

      assert gitignore =~ ~r/^\.env$/m
      assert gitignore =~ ~r/^\.mise\.local\.toml$/m
    end

    test "keeps what was already there" do
      original = "/_build/\n/deps/\n*.ez\n"

      gitignore =
        test_project(files: %{".gitignore" => original}) |> Gen.ignore([".env"]) |> gitignore()

      assert String.starts_with?(gitignore, original)
    end

    test "is safe to re-run: no line is added twice" do
      gitignore =
        test_project()
        |> Gen.ignore([".env", ".mise.local.toml"])
        |> Gen.ignore([".env", ".mise.local.toml"])
        |> gitignore()

      assert count(gitignore, ~r/^\.env$/m) == 1
      assert count(gitignore, ~r/^\.mise\.local\.toml$/m) == 1
    end

    test "starts a new line when the file does not end with one" do
      gitignore =
        test_project(files: %{".gitignore" => "/_build/"})
        |> Gen.ignore([".env"])
        |> gitignore()

      assert gitignore == "/_build/\n.env\n"
    end
  end

  describe "next_steps/2" do
    test "points at mise by default, and names what it runs" do
      assert Gen.next_steps(:api, []) =~ "mise trust && mise run dev"
      assert Gen.next_steps(:api, []) =~ "mix phx.server"
      assert Gen.next_steps(:worker, []) =~ "mix run --no-halt"
      assert Gen.next_steps(:worker, []) =~ "mise run health"
    end

    test "falls back to compose, then to nothing, as the generated tooling shrinks" do
      assert Gen.next_steps(:api, mise: false) =~
               "docker compose up -d --wait && cp .env.example .env && . ./.env && mix ash.setup && mix phx.server"

      assert Gen.next_steps(:api, mise: false, compose: false) ==
               "Next: mix ash.setup && mix phx.server"
    end

    test "does not promise services when compose was skipped" do
      assert Gen.next_steps(:api, compose: false) =~ "sets up the database"
      refute Gen.next_steps(:api, compose: false) =~ "starts the services"
    end
  end

  defp gitignore(igniter) do
    igniter.rewrite
    |> Rewrite.source!(".gitignore")
    |> Rewrite.Source.get(:content)
  end

  defp count(string, regex), do: regex |> Regex.scan(string) |> length()
end
