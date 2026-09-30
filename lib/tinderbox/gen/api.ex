defmodule Tinderbox.Gen.Api do
  @moduledoc """
  Generates the API stack: Phoenix (API-only) + Ash + AshPostgres + AshJsonApi +
  AshPhoenix, with a demo JSON:API resource mounted at `/api`.

  Igniter installs those packages and runs `ash.install`, `ash_postgres.install`
  and `ash_json_api.install` *before* this module runs — they are declared as
  `installs:`/`composes:` in `Mix.Tasks.Tinderbox.Gen.Api.info/2`, and those
  installers already create `<App>.Repo`, add it to the supervision tree, and
  create `<App>Web.AshJsonApiRouter`. This module only adds what is
  stack-specific:

  * the object storage wiring both stacks share (`Tinderbox.Gen.Storage`),
  * a demo domain + JSON:API resource (`--demo`, on by default),
  * the demo domain in `config :<app>, ash_domains: [...]` and in the router's
    `domains:` list (both installers ran before the domain existed),
  * the `/api` mount for the AshJsonApi router,
  * the notice with the run instructions.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Storage

  # The package is consumed as a local path dependency, so the "regenerate from
  # scratch" hint has to name the path. See the README.
  @package_path "/Users/jamescarr/projects/upmarkethq/tinderbox"

  @spec apply(Igniter.t(), Keyword.t()) :: Igniter.t()
  def apply(igniter, opts) do
    require_phoenix!(igniter)

    prefix = Igniter.Project.Module.module_name_prefix(igniter)
    app = Igniter.Project.Application.app_name(igniter)
    json_api_router = Igniter.Libs.Phoenix.web_module_name(igniter, "AshJsonApiRouter")

    {igniter, demo_domain} =
      add_demo_domain(igniter, Keyword.get(opts, :demo, true), prefix, app)

    igniter
    |> Storage.apply(opts)
    |> mount_json_api(json_api_router, demo_domain)
    |> Igniter.add_notice(Gen.next_steps(:api, opts))
  end

  defp require_phoenix!(igniter) do
    case Igniter.Libs.Phoenix.list_routers(igniter) do
      {_igniter, []} ->
        Mix.raise("""
        The API stack requires a Phoenix project. Generate it with:

            mix igniter.new my_api --with phx.new \\
              --with-args="--no-html --no-assets --no-live --no-dashboard --no-mailer --no-gettext" \\
              --install tinderbox@path:#{@package_path} \\
              --stack api
        """)

      {_igniter, _routers} ->
        igniter
    end
  end

  defp add_demo_domain(igniter, false, _prefix, _app), do: {igniter, nil}

  defp add_demo_domain(igniter, true, prefix, app) do
    catalog = Module.concat(prefix, Catalog)
    item = Module.concat(prefix, Catalog.Item)
    assigns = [catalog: catalog, item: item, repo: Module.concat(prefix, Repo)]

    igniter =
      igniter
      |> Igniter.Project.Module.create_module(
        catalog,
        Gen.render_template("api/catalog.ex.eex", assigns)
      )
      |> Igniter.Project.Module.create_module(
        item,
        Gen.render_template("api/catalog_item.ex.eex", assigns)
      )
      |> Igniter.Project.Config.configure(
        "config.exs",
        app,
        [:ash_domains],
        [catalog],
        updater: fn zipper -> Igniter.Code.List.prepend_new_to_list(zipper, catalog) end
      )

    {igniter, catalog}
  end

  # The AshJsonApi installer forwarded its router at `/api/json` and created it
  # with an empty `domains:` list (the demo domain did not exist yet). The API
  # stack's contract is `/api`, so the router gets its own alias-free
  # `scope "/api"` next to the installer's; swagger UI and the OpenAPI document
  # stay where the installer put them, under `/api/json`.
  #
  # No `arg2:` on purpose: `scope "/api", <WebModule>` pushes a scope alias, and
  # Phoenix resolves module references inside such a scope *relative to that
  # alias* — `forward "/", MyAppWeb.AshJsonApiRouter` would become
  # `MyAppWeb.MyAppWeb.AshJsonApiRouter`.
  @doc false
  def mount_json_api(igniter, json_api_router, demo_domain) do
    case Igniter.Libs.Phoenix.list_routers(igniter) do
      {igniter, []} ->
        igniter

      {igniter, [router | _]} ->
        igniter = add_domain_to_router(igniter, json_api_router, demo_domain)
        {igniter, mounted?} = mounted?(igniter, router, json_api_router)

        if mounted? do
          igniter
        else
          Igniter.Libs.Phoenix.append_to_scope(
            igniter,
            "/api",
            "forward \"/\", #{inspect(json_api_router)}",
            router: router,
            with_pipelines: [:api],
            # Appended *after* the installer's `/api/json` scope: `forward "/"` in
            # a scope matches every path under its prefix, so mounting `/api` first
            # would make the installer's swagger UI scope unreachable (and the
            # router would fail to compile with warnings-as-errors).
            placement: :after
          )
        end
    end
  end

  # True when an alias-free `scope "/api"` already forwards to the router.
  # `append_to_scope/4` does not look before it adds, so without this a re-run
  # stacks a second `forward` that can never match — the same
  # warnings-as-errors failure the ordering above exists to avoid.
  defp mounted?(igniter, phoenix_router, json_api_router) do
    case Igniter.Project.Module.find_module(igniter, phoenix_router) do
      {:ok, {igniter, _source, zipper}} ->
        found? =
          with {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper),
               {:ok, zipper} <-
                 Igniter.Code.Function.move_to_function_call_in_current_scope(
                   zipper,
                   :scope,
                   [2],
                   &Igniter.Code.Function.argument_equals?(&1, 0, "/api")
                 ),
               {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper),
               {:ok, _zipper} <-
                 Igniter.Code.Function.move_to_function_call_in_current_scope(
                   zipper,
                   :forward,
                   2,
                   &Igniter.Code.Function.argument_equals?(&1, 1, json_api_router)
                 ) do
            true
          else
            _ -> false
          end

        {igniter, found?}

      {:error, igniter} ->
        {igniter, false}
    end
  end

  defp add_domain_to_router(igniter, _json_api_router, nil), do: igniter

  defp add_domain_to_router(igniter, json_api_router, domain) do
    case Igniter.Project.Module.module_exists(igniter, json_api_router) do
      {false, igniter} ->
        igniter

      {true, igniter} ->
        Igniter.Project.Module.find_and_update_module!(igniter, json_api_router, fn zipper ->
          with {:ok, zipper} <-
                 Igniter.Code.Module.move_to_use(zipper, ash_json_api_router_plug()),
               {:ok, zipper} <- Igniter.Code.Function.move_to_nth_argument(zipper, 1),
               {:ok, zipper} <- Igniter.Code.Keyword.get_key(zipper, :domains),
               {:ok, zipper} <- Igniter.Code.List.prepend_new_to_list(zipper, domain) do
            {:ok, zipper}
          else
            _ ->
              {:warning,
               "Could not add #{inspect(domain)} to the `domains:` option of " <>
                 "#{inspect(json_api_router)}. Add it manually."}
          end
        end)
    end
  end

  # Referenced by name so this package does not need ash_json_api to compile.
  defp ash_json_api_router_plug, do: Igniter.Project.Module.parse("AshJsonApi.Router")
end
