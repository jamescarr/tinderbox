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
  Creates each `{module, template}` (a path under `priv/templates`), rendering the
  template with `assigns`; `opts` go to `Igniter.Project.Module.create_module/4`
  (e.g. `location: :test_support`).
  """
  @spec create_modules(Igniter.t(), [{module(), Path.t()}], keyword(), keyword()) :: Igniter.t()
  def create_modules(igniter, modules, assigns, opts \\ []) do
    Enum.reduce(modules, igniter, fn {module, template}, igniter ->
      Igniter.Project.Module.create_module(
        igniter,
        module,
        render_template(template, assigns),
        opts
      )
    end)
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

  @doc "The `configured?` check for `append_to_runtime_exs/3`: `config root_key, …` sets `path` in runtime.exs (`path: []` checks the root key alone)."
  @spec runtime_configures?(atom(), [term()]) :: (Igniter.t() -> boolean())
  def runtime_configures?(root_key, path \\ []) do
    &Igniter.Project.Config.configures_key?(&1, "runtime.exs", root_key, path)
  end

  @doc """
  Applies `fun` to the content of the file at `path`: `{:ok, new_content}`
  rewrites it, `{:warning, message}` leaves it alone and warns. A missing file is
  warned about rather than created.
  """
  @spec update_file(
          Igniter.t(),
          Path.t(),
          (String.t() -> {:ok, String.t()} | {:warning, String.t()})
        ) :: Igniter.t()
  def update_file(igniter, path, fun) do
    if Igniter.exists?(igniter, path) do
      igniter = Igniter.include_existing_file(igniter, path)
      source = Rewrite.source!(igniter.rewrite, path)

      case fun.(Rewrite.Source.get(source, :content)) do
        {:ok, content} -> Igniter.update_file(igniter, path, &set_content(&1, igniter, content))
        {:warning, message} -> Igniter.add_warning(igniter, message)
      end
    else
      Igniter.add_warning(igniter, "#{path} does not exist, so it was not edited.")
    end
  end

  defp set_content(source, igniter, content) do
    if Rewrite.Source.get(source, :content) == content do
      source
    else
      Igniter.update_source(source, igniter, :content, content)
    end
  end

  @doc """
  Replaces the whole of `module` with `body` (a module body, like every
  template) when `replace?` returns true for its current source, and creates
  the module when it does not exist.

  `replace?` is how a generator recognizes a file it may overwrite: Phoenix's
  untouched demo layout, say, rather than one the developer has customized.
  """
  @spec replace_module(Igniter.t(), module(), String.t(), (String.t() -> boolean())) ::
          Igniter.t()
  def replace_module(igniter, module, body, replace?) when is_function(replace?, 1) do
    case Igniter.Project.Module.module_exists(igniter, module) do
      {true, igniter} ->
        rewrite_module(igniter, module, fn current ->
          {:ok, if(replace?.(current), do: module_source(module, body), else: current)}
        end)

      {false, igniter} ->
        Igniter.Project.Module.create_module(igniter, module, body)
    end
  end

  @doc """
  Rewrites `module`'s source through `fun`, which gets the source text and
  returns `{:ok, new_source}` or `{:warning, message}`. Returning the text it
  was given leaves the file alone. A module that does not exist is left alone.

  The rewrite goes through the Elixir updater, so the project's formatter (with
  the HEEx plugin) runs on the result; a plain file write would not be formatted.
  """
  @spec rewrite_module(Igniter.t(), module(), (String.t() ->
                                                 {:ok, String.t()} | {:warning, String.t()})) ::
          Igniter.t()
  def rewrite_module(igniter, module, fun) when is_function(fun, 1) do
    case Igniter.Project.Module.find_module(igniter, module) do
      {:ok, {igniter, source, _zipper}} ->
        Igniter.update_elixir_file(igniter, source.path, fn zipper ->
          current = zipper |> Sourceror.Zipper.root() |> Sourceror.to_string()

          case fun.(current) do
            {:ok, ^current} ->
              {:ok, zipper}

            {:ok, new} ->
              {:ok, new |> Sourceror.parse_string!() |> Sourceror.Zipper.zip()}

            {:warning, message} ->
              {:warning, message}
          end
        end)

      {:error, igniter} ->
        igniter
    end
  end

  # Templates are module bodies; this wraps one for a whole-file write.
  defp module_source(module, body) do
    "defmodule #{inspect(module)} do\n#{body}\nend\n"
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
