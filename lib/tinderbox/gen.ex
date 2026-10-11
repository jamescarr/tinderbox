defmodule Tinderbox.Gen do
  @moduledoc """
  Helpers shared by the `Tinderbox.Gen.*` generators.

  Every file a generator writes is rendered from `priv/templates` so the
  generated code can be reviewed as plain Elixir/YAML instead of as a heredoc
  inside a generator. Generators only compute assigns.
  """

  @doc "Absolute path of a template in this package's `priv/templates`."
  @spec template_path(Path.t()) :: Path.t()
  def template_path(name) do
    Path.join([Application.app_dir(:tinderbox, "priv/templates"), name])
  end

  @doc """
  Renders a template, returning the result as a string.

  Used for module bodies handed to `Igniter.Project.Module.create_module/4`,
  which supplies the surrounding `defmodule`.
  """
  @spec render_template(Path.t(), Keyword.t()) :: String.t()
  def render_template(name, assigns) do
    EEx.eval_file(template_path(name), assigns: assigns)
  end

  @doc """
  Appends `code` to `config/runtime.exs`, creating the file when it is missing.

  `configured?` gets the igniter and reports whether the config is already
  present, so re-running a generator is a no-op.

  The code is appended at the *end* of the file rather than inside a block:
  Phoenix wraps its own runtime config in `if config_env() == :prod`, and this
  config has to apply in every environment.
  """
  @spec append_to_runtime_exs(Igniter.t(), String.t(), (Igniter.t() -> boolean())) :: Igniter.t()
  def append_to_runtime_exs(igniter, code, configured?) when is_function(configured?, 1) do
    if configured?.(igniter) do
      igniter
    else
      Igniter.create_or_update_elixir_file(
        igniter,
        "config/runtime.exs",
        # `create_or_update_elixir_file/4` writes this verbatim when the file
        # does not exist, so it has to be the complete contents, not a seed.
        "import Config\n\n" <> code,
        fn zipper -> Igniter.Code.Common.add_code(zipper, code) end
      )
    end
  end

  @doc """
  Ensures every line in `lines` is in `.gitignore`, creating the file when it is
  missing. Lines already present are left alone, so this is safe to re-run.

  Used for the files a developer creates locally and must not commit: `.env`
  (copied from `.env.example`), `docker-compose.override.yml` and
  `.mise.local.toml` (machine-specific overrides).
  """
  @spec ignore(Igniter.t(), [String.t()]) :: Igniter.t()
  def ignore(igniter, lines) do
    Igniter.create_or_update_file(
      igniter,
      ".gitignore",
      # Written verbatim when the file does not exist.
      Enum.join(lines, "\n") <> "\n",
      fn source ->
        content = Rewrite.Source.get(source, :content)
        present = content |> String.split("\n", trim: true) |> MapSet.new(&String.trim/1)

        case Enum.reject(lines, &MapSet.member?(present, &1)) do
          [] ->
            source

          missing ->
            separator = if content == "" or String.ends_with?(content, "\n"), do: "", else: "\n"
            addition = content <> separator <> Enum.join(missing, "\n") <> "\n"
            Igniter.update_source(source, igniter, :content, addition)
        end
      end
    )
  end

  # The package is consumed as a local path dependency, so the "regenerate from
  # scratch" hints in the generators' errors have to name the path. See the README.
  @package_path "/Users/jamescarr/projects/upmarkethq/tinderbox"

  @doc "Where this package lives on the author's machine, for the generators' error hints."
  @spec package_path() :: Path.t()
  def package_path, do: @package_path

  @doc """
  The "what now?" notice a stack generator prints, matching the tooling that was
  generated: mise (`--no-mise` skips it), docker compose (`--no-compose` skips
  it), or neither.
  """
  @spec next_steps(:api | :worker | :saas, Keyword.t()) :: String.t()
  def next_steps(stack, opts) do
    serve = if stack == :worker, do: "mix run --no-halt", else: "mix phx.server"
    health = if stack == :worker, do: " (health: `mise run health`)", else: ""

    cond do
      Keyword.get(opts, :mise, true) ->
        "Next: mise trust && mise run dev   # #{steps(opts)}, then #{serve}#{health}" <>
          saas_tail(stack, opts, "run `mise run stripe`") <>
          "; `mise tasks` lists the rest"

      Keyword.get(opts, :compose, true) ->
        "Next: docker compose up -d --wait && cp .env.example .env && . ./.env && " <>
          "mix ash.setup && #{serve}" <>
          if(stack == :worker, do: "   (health: curl localhost:4001/health)", else: "") <>
          saas_tail(stack, opts, nil)

      true ->
        "Next: mix ash.setup && #{serve}"
    end
  end

  # What to do once the SaaS app is up. The local SSO provider and the mail sink
  # are compose services, so there is nothing to say without compose.
  defp saas_tail(:saas, opts, stripe_cli) do
    if Keyword.get(opts, :compose, true) do
      stripe =
        "Stripe: put STRIPE_SECRET_KEY, STRIPE_PRICE_STARTER, STRIPE_PRICE_PRO in " <>
          if(stripe_cli, do: ".mise.local.toml and #{stripe_cli}", else: ".env")

      "; then open http://localhost:4000 — SSO: admin@example.com / password (Dex), " <>
        "mail: http://localhost:8025 (Mailpit), " <> stripe
    else
      ""
    end
  end

  defp saas_tail(_stack, _opts, _stripe_cli), do: ""

  defp steps(opts) do
    if Keyword.get(opts, :compose, true),
      do: "starts the services, sets up the database",
      else: "sets up the database"
  end
end
