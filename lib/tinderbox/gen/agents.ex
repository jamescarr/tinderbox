defmodule Tinderbox.Gen.Agents do
  @moduledoc """
  Puts a tinderbox agent map at the top of `AGENTS.md`.

  `phx.new` writes its own `AGENTS.md` (framework guidelines, 300+ lines), and
  the generated project's own rules — the gate, mise, the generators, worktrees —
  have to be read before those. The map is one delimited block
  (`<!-- tinderbox:map:start -->` … `<!-- tinderbox:map:end -->`), so re-running
  replaces it instead of stacking a second copy.

  Two of Phoenix's stock lines contradict a tinderbox project and are rewritten
  in place: `mix precommit` is not the gate (`mise run check` is), and the SaaS
  stack is built on daisyUI, so "write your own tailwind components" is wrong
  there. A stock line that is not found is left alone and reported as a notice —
  `phx.new`'s wording is not ours to assume.

  Without an `AGENTS.md` the map is the whole file.

  Called by `Tinderbox.Gen.Mise.apply/2`, so `--no-mise` skips it too.
  """

  alias Tinderbox.Gen

  @start "<!-- tinderbox:map:start -->"
  @stop "<!-- tinderbox:map:end -->"

  @precommit "- Use `mix precommit` alias when you are done with all changes and fix any pending issues"
  @precommit_replacement "- Run `mise run check` when you are done with all changes and fix any pending issues; it is the gate CI runs"
  @daisy "- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design"

  @doc """
  Renders `agents-map.md.eex` with `assigns` (`:app`, `:module`, `:stack`,
  `:compose?`, `:saas?`) and writes it into `AGENTS.md`.
  """
  @spec apply(Igniter.t(), Keyword.t()) :: Igniter.t()
  def apply(igniter, assigns) do
    map =
      "agents-map.md.eex"
      |> Gen.render_template(assigns)
      |> String.trim_trailing()

    if Igniter.exists?(igniter, "AGENTS.md") do
      igniter = Igniter.include_existing_file(igniter, "AGENTS.md")
      current = igniter.rewrite |> Rewrite.source!("AGENTS.md") |> Rewrite.Source.get(:content)
      {content, missing} = merge(current, map, assigns)

      igniter
      |> Gen.update_file("AGENTS.md", fn _content -> {:ok, content} end)
      |> add_notices(missing)
    else
      Igniter.create_new_file(igniter, "AGENTS.md", map <> "\n")
    end
  end

  # The map goes first (replacing an earlier copy), then the two stock lines that
  # contradict this project. A line counts as handled when it is already gone
  # because an earlier run rewrote or deleted it.
  defp merge(content, map, assigns) do
    first_run? = not String.contains?(content, @start)
    stock = if assigns[:saas?], do: [@precommit, @daisy], else: [@precommit]
    missing = if first_run?, do: Enum.reject(stock, &String.contains?(content, &1)), else: []

    content =
      content
      |> put_map(map)
      |> replace_line(@precommit, @precommit_replacement)

    content = if assigns[:saas?], do: delete_line(content, @daisy), else: content

    {content, missing}
  end

  defp put_map(content, map) do
    block = ~r/#{Regex.escape(@start)}.*?#{Regex.escape(@stop)}/s

    if Regex.match?(block, content) do
      Regex.replace(block, content, fn _block -> map end)
    else
      map <> "\n\n" <> content
    end
  end

  defp replace_line(content, line, replacement) do
    content
    |> String.split("\n")
    |> Enum.map(fn
      ^line -> replacement
      other -> other
    end)
    |> Enum.join("\n")
  end

  defp delete_line(content, line) do
    content
    |> String.split("\n")
    |> Enum.reject(&(&1 == line))
    |> Enum.join("\n")
  end

  defp add_notices(igniter, []), do: igniter

  defp add_notices(igniter, missing) do
    Enum.reduce(missing, igniter, fn line, igniter ->
      Igniter.add_notice(
        igniter,
        "AGENTS.md has no stock line #{inspect(line)}, so it was left as it is; " <>
          "the map at its top says what replaces it."
      )
    end)
  end
end
