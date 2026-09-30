defmodule UpmarketStack.Gen do
  @moduledoc """
  Helpers shared by the `UpmarketStack.Gen.*` generators.

  Every file a generator writes is rendered from `priv/templates` so the
  generated code can be reviewed as plain Elixir/YAML instead of as a heredoc
  inside a generator. Generators only compute assigns.
  """

  @doc "Absolute path of a template in this package's `priv/templates`."
  @spec template_path(Path.t()) :: Path.t()
  def template_path(name) do
    Path.join([Application.app_dir(:upmarket_stack, "priv/templates"), name])
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
end
