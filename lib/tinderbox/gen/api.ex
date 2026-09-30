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
    |> Igniter.add_notice(
      "Next: docker compose up -d --wait && cp .env.example .env && source .env && " <>
        "mix ash.setup && mix phx.server"
    )
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
  defp mount_json_api(igniter, json_api_router, demo_domain) do
    {igniter, routers} = Igniter.Libs.Phoenix.list_routers(igniter)

    case routers do
      [] ->
        igniter

      routers ->
        igniter
        |> add_domain_to_router(json_api_router, demo_domain)
        |> Igniter.Libs.Phoenix.append_to_scope(
          "/api",
          "forward \"/\", #{inspect(json_api_router)}",
          router: List.first(routers),
          with_pipelines: [:api],
          # Appended *after* the installer's `/api/json` scope: `forward "/"` in
          # a scope matches every path under its prefix, so mounting `/api` first
          # would make the installer's swagger UI scope unreachable (and the
          # router would fail to compile with warnings-as-errors).
          placement: :after
        )
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
               {:ok, zipper} <- Igniter.Code.Keyword.get_key(zipper, :domains) do
            # `prepend_new_to_list/3` already returns `{:ok, zipper} | :error`.
            Igniter.Code.List.prepend_new_to_list(zipper, domain)
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
