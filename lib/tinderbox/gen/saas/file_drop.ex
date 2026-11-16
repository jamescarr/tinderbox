defmodule Tinderbox.Gen.Saas.FileDrop do
  @moduledoc """
  The file drop (`--file-drop`, or `mix tinderbox.gen.file_drop` on an existing SaaS
  project): an organization's owners and admins drop files at `/drop`, and each one
  is checked, stored, scanned and handed to the application.

    * `<App>.FileDrop` - the Ash domain and the way in (`receive_file/4`,
      `receive_binary/5`): size limit, type sniffed from the bytes, sha256
      deduplication per organization, a server-chosen key under
      `drop/<organization id>/` in `<App>.Storage`,
    * `<App>.FileDrop.Upload` - the record of a file, whose `:ingest` AshOban
      trigger (queue `file_drop`) scans it and hands it to the handler,
    * `<App>.FileDrop.Sniff`, `.Scanner` (`FILE_DROP_SCANNER`: `none`, or `clamav`
      for `.Scanners.ClamAV`, a `clamd` INSTREAM client), `.Handler` (the behaviour
      the application implements; `.Handlers.Keep` until it does),
    * `<App>Web.FileDropLive` (`/drop`) and `<App>Web.FileDropController`
      (`GET /drop/:id/download`, always an attachment), a Files entry in the
      navigation, `upload_fixture/3` in `<App>.Fixtures`, and tests.

  Configuration: the handler and the accepted extensions in `config.exs`; the
  scanner, the size limit and clamd's address in `runtime.exs`, where production
  refuses to boot without `FILE_DROP_SCANNER`. Edits to existing files are
  guarded, so applying twice changes nothing.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits

  @extensions [".csv", ".ofx", ".qfx", ".pdf", ".zip", ".eml", ".txt"]
  @platform_nav ~s(<.nav_section :if={@current_user.role == :admin})

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    {igniter, assigns} = assigns(igniter, assigns)

    igniter
    |> create_modules(assigns)
    |> register_domain(assigns)
    |> add_queue(assigns)
    |> add_config(assigns)
    |> add_runtime_config(assigns)
    |> add_routes(assigns)
    |> add_navigation(assigns)
    |> add_fixture(assigns)
    |> add_tests(assigns)
  end

  @doc """
  Adds the file drop to a project generated with `--stack saas`: what
  `mix tinderbox.gen.file_drop` runs. Raises when the project is not a SaaS
  project, or already has it.
  """
  @spec install(Igniter.t(), keyword()) :: Igniter.t()
  def install(igniter, opts) do
    {igniter, assigns} = Tinderbox.Gen.Saas.assigns(igniter, opts)
    file_drop = Module.concat(assigns[:prefix], "FileDrop")

    igniter = require_saas!(igniter, assigns, "mix tinderbox.gen.file_drop adds the file drop")

    {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, file_drop)

    if exists? do
      Mix.raise("#{inspect(file_drop)} already exists: this project has the file drop.")
    end

    igniter
    |> __MODULE__.apply(assigns)
    |> Ash.Igniter.codegen("add_file_drop")
    # Ash formats the migration once, and `mix format --check-formatted` would
    # fail on the fresh file (see `Tinderbox.Gen.Saas.generate/2`).
    |> Igniter.add_task("format", ["priv/repo/migrations/*add_file_drop.exs"])
    |> Igniter.add_notice(notice())
  end

  @doc false
  @spec notice() :: String.t()
  def notice do
    "File drop added at /drop. Run `mix ash.migrate`. FILE_DROP_SCANNER is `none` " <>
      "outside production and required in production: `clamav` (with CLAMAV_HOST and " <>
      "CLAMAV_PORT) or `none`. A local clamd: docker run -p 3310:3310 clamav/clamav-debian:1.5."
  end

  @doc false
  # The project is a `--stack saas` project; `what` starts the error otherwise.
  @spec require_saas!(Igniter.t(), keyword(), String.t()) :: Igniter.t()
  def require_saas!(igniter, assigns, what) do
    live_organization = Module.concat(assigns[:web], "LiveOrganization")

    case Igniter.Project.Module.module_exists(igniter, live_organization) do
      {true, igniter} ->
        igniter

      {false, _igniter} ->
        Mix.raise(
          "#{what} to a project generated with --stack saas, and " <>
            "#{inspect(live_organization)} is missing."
        )
    end
  end

  @doc false
  # The assigns the templates need on top of `t:Tinderbox.Gen.Saas.assigns/0`. A
  # project generated before the activity feed has no `<Accounts>.VersionIndexes`.
  @spec assigns(Igniter.t(), keyword()) :: {Igniter.t(), keyword()}
  def assigns(igniter, assigns) do
    {version_indexes?, igniter} =
      Igniter.Project.Module.module_exists(
        igniter,
        Module.concat(assigns[:accounts], "VersionIndexes")
      )

    {igniter,
     Keyword.merge(assigns,
       file_drop: Module.concat(assigns[:prefix], "FileDrop"),
       integrations: Module.concat(assigns[:prefix], "Integrations"),
       vault: Module.concat(assigns[:prefix], "Vault"),
       version_indexes?: version_indexes?
     )}
  end

  # -- modules ------------------------------------------------------------------

  defp create_modules(igniter, assigns) do
    file_drop = assigns[:file_drop]
    web = assigns[:web]

    modules = [
      {file_drop, "file_drop.ex.eex"},
      {Module.concat(file_drop, "Upload"), "upload.ex.eex"},
      {Module.concat(file_drop, "Sniff"), "sniff.ex.eex"},
      {Module.concat(file_drop, "Scanner"), "scanner.ex.eex"},
      {Module.concat([file_drop, "Scanners", "ClamAV"]), "scanners/clam_av.ex.eex"},
      {Module.concat(file_drop, "Handler"), "handler.ex.eex"},
      {Module.concat([file_drop, "Handlers", "Keep"]), "handlers/keep.ex.eex"},
      {Module.concat([file_drop, "Changes", "Ingest"]), "changes/ingest.ex.eex"},
      {Module.concat([file_drop, "Changes", "DeleteObject"]), "changes/delete_object.ex.eex"},
      {Module.concat([file_drop, "Changes", "Broadcast"]), "changes/broadcast.ex.eex"},
      {Module.concat(web, "FileDropLive"), "file_drop_live.ex.eex"},
      {Module.concat(web, "FileDropController"), "file_drop_controller.ex.eex"}
    ]

    Gen.create_modules(
      igniter,
      Enum.map(modules, fn {module, template} -> {module, "saas/file_drop/#{template}"} end),
      assigns
    )
  end

  # -- config -------------------------------------------------------------------

  defp register_domain(igniter, assigns) do
    domain = assigns[:file_drop]

    Igniter.Project.Config.configure(
      igniter,
      "config.exs",
      assigns[:app],
      [:ash_domains],
      [domain],
      updater: fn zipper -> Igniter.Code.List.prepend_new_to_list(zipper, domain) end
    )
  end

  # The `:ingest` trigger runs on its own `file_drop` queue.
  defp add_queue(igniter, assigns) do
    Igniter.Project.Config.configure(
      igniter,
      "config.exs",
      assigns[:app],
      [Oban, :queues],
      [file_drop: 2],
      updater: fn zipper ->
        Igniter.Code.Keyword.set_keyword_key(zipper, :file_drop, 2, fn queue -> {:ok, queue} end)
      end
    )
  end

  defp add_config(igniter, assigns) do
    file_drop = assigns[:file_drop]
    app = assigns[:app]

    igniter
    |> Igniter.Project.Config.configure_new(
      "config.exs",
      app,
      [file_drop, :handler],
      Module.concat([file_drop, "Handlers", "Keep"])
    )
    |> Igniter.Project.Config.configure_new(
      "config.exs",
      app,
      [file_drop, :extensions],
      @extensions
    )
  end

  defp add_runtime_config(igniter, assigns) do
    Gen.append_to_runtime_exs(
      igniter,
      render("runtime_config.exs.eex", assigns),
      Gen.runtime_contains?("FILE_DROP_SCANNER")
    )
  end

  # -- routes and navigation ----------------------------------------------------------

  defp add_routes(igniter, assigns) do
    router = assigns[:router]
    live_route = ~s(live "/drop", FileDropLive)

    igniter
    |> Edits.unless_contains(
      router,
      live_route,
      &Edits.add_to_live_session(&1, router, :authenticated_routes, live_route)
    )
    # A plain controller route, like the `file` attribute downloads: a LiveView
    # cannot send a file.
    |> Edits.unless_contains(router, "FileDropController", fn igniter ->
      Igniter.Libs.Phoenix.append_to_scope(
        igniter,
        "/",
        ~s(get "/drop/:id/download", FileDropController, :download),
        with_pipelines: [:browser],
        arg2: assigns[:web],
        router: router
      )
    end)
  end

  @nav_entry ~s(<.nav_item navigate={~p"/drop"} icon="hero-arrow-up-tray" active={@current_page == :drop}>Files</.nav_item>)

  defp add_navigation(igniter, assigns) do
    layouts = Module.concat(assigns[:web], "Layouts")

    Gen.rewrite_module(igniter, layouts, fn content ->
      cond do
        String.contains?(content, ~s(~p"/drop")) ->
          {:ok, content}

        new = Edits.insert_line(content, @platform_nav, @nav_entry, :before) ->
          {:ok, new}

        true ->
          {:warning,
           "Could not add Files to the navigation in #{inspect(layouts)}; add " <>
             "#{@nav_entry} to its nav slot by hand."}
      end
    end)
  end

  # -- test support and tests -------------------------------------------------------

  defp add_fixture(igniter, assigns) do
    fixtures = Module.concat(assigns[:prefix], "Fixtures")

    Edits.unless_contains(igniter, fixtures, "def upload_fixture(", fn igniter ->
      Edits.append_to_module(igniter, fixtures, render("fixture.ex.eex", assigns))
    end)
  end

  defp add_tests(igniter, assigns) do
    app = assigns[:app]

    [
      {"test/#{app}/file_drop_test.exs", "file_drop_test.exs.eex"},
      {"test/#{app}/file_drop/clam_av_test.exs", "clam_av_test.exs.eex"},
      {"test/#{app}_web/live/file_drop_live_test.exs", "file_drop_live_test.exs.eex"},
      {"test/#{app}_web/controllers/file_drop_controller_test.exs",
       "file_drop_controller_test.exs.eex"}
    ]
    |> Enum.reduce(igniter, fn {path, template}, igniter ->
      Igniter.create_new_file(igniter, path, render(template, assigns))
    end)
  end

  defp render(template, assigns), do: Gen.render_template("saas/file_drop/#{template}", assigns)
end
