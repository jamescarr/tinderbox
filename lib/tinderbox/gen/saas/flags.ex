defmodule Tinderbox.Gen.Saas.Flags do
  @moduledoc """
  Feature flags (FunWithFlags) and the admin guard that protects them.

  * `<App>Web.Plugs.RequireAdmin` — a plug that answers 404 to anyone who is not a
    platform admin; `<App>Web.LiveAdmin` — the equivalent LiveView `on_mount`,
  * FunWithFlags configuration in `config/config.exs`: flags persisted through
    `<App>.Repo` (`:binary_id` keys), cache-busting over `<App>.PubSub`,
  * the `fun_with_flags_toggles` migration (FunWithFlags' own, with a
    `:binary_id` key), skipped when the project already has one,
  * the start order: both packages are `runtime: false` dependencies, named in the
    project's `releases:` (loaded, not started), and `FunWithFlags.Supervisor` is a
    child of the application supervisor after `<App>.PubSub`. Left to start on its
    own, FunWithFlags comes up before the host application and gives up subscribing
    to a `Phoenix.PubSub` that does not exist yet after five tries one second apart,
    which a slow boot exceeds (see "Application Start Behaviour" in its README),
  * `<App>.FeatureFlags` — the actor and group implementations for users and
    organizations,
  * the `FunWithFlags.UI` dashboard at `/admin/flags`, behind `RequireAdmin` in its
    own `admin_tools` pipeline. It is not a LiveView, so it cannot share the
    admin section's live session; it has its own CSRF protection, and needs only
    the session the endpoint already provides.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits

  @migration "priv/repo/migrations/20250101000000_create_fun_with_flags_toggles.exs"

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    igniter
    |> create_modules(assigns)
    |> configure(assigns)
    |> start_with_the_application(assigns)
    |> add_migration(assigns)
    |> mount_dashboard(assigns)
  end

  # The dependencies are declared `runtime: false` (see
  # `Mix.Tasks.Tinderbox.Gen.Saas`), so `:fun_with_flags` does not start on its own;
  # `FunWithFlags.Supervisor` starts in the application tree instead. A release
  # leaves out such an application unless it is named, hence `releases:`. The
  # README's other option, `included_applications`, is rejected by `mix release`
  # because `fun_with_flags_ui` lists `:fun_with_flags` among the applications it
  # needs.
  defp start_with_the_application(igniter, assigns) do
    igniter
    |> Igniter.Project.MixProject.update(
      :project,
      [:releases, assigns[:app], :applications],
      fn
        nil ->
          {:ok, {:code, quote(do: [fun_with_flags: :load, fun_with_flags_ui: :load])}}

        zipper ->
          keep = fn zipper -> {:ok, zipper} end

          with {:ok, zipper} <-
                 Igniter.Code.Keyword.set_keyword_key(zipper, :fun_with_flags, :load, keep),
               do: Igniter.Code.Keyword.set_keyword_key(zipper, :fun_with_flags_ui, :load, keep)
      end
    )
    |> Edits.add_child_after(
      Module.concat(assigns[:prefix], "Application"),
      FunWithFlags.Supervisor,
      "FunWithFlags.Supervisor",
      Phoenix.PubSub
    )
  end

  defp create_modules(igniter, assigns) do
    modules = [
      {Module.concat([assigns[:web], "Plugs", "RequireAdmin"]),
       "saas/flags/require_admin.ex.eex"},
      {Module.concat(assigns[:web], "LiveAdmin"), "saas/flags/live_admin.ex.eex"},
      {Module.concat(assigns[:prefix], "FeatureFlags"), "saas/flags/feature_flags.ex.eex"}
    ]

    Gen.create_modules(igniter, modules, assigns)
  end

  defp configure(igniter, assigns) do
    igniter
    |> Igniter.Project.Config.configure(
      "config.exs",
      :fun_with_flags,
      [:persistence],
      adapter: FunWithFlags.Store.Persistent.Ecto,
      repo: assigns[:repo],
      ecto_primary_key_type: :binary_id
    )
    |> Igniter.Project.Config.configure(
      "config.exs",
      :fun_with_flags,
      [:cache_bust_notifications],
      enabled: true,
      adapter: FunWithFlags.Notifications.PhoenixPubSub,
      client: assigns[:pubsub]
    )
  end

  defp add_migration(igniter, assigns) do
    if migration_exists?(igniter) do
      igniter
    else
      Igniter.create_new_file(
        igniter,
        @migration,
        Gen.render_template("saas/flags/create_fun_with_flags_toggles.exs.eex", assigns)
      )
    end
  end

  defp migration_exists?(igniter) do
    in_igniter? =
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.any?(&String.ends_with?(&1.path, "_create_fun_with_flags_toggles.exs"))

    in_igniter? or
      Path.wildcard("priv/repo/migrations/*_create_fun_with_flags_toggles.exs") != []
  end

  defp mount_dashboard(igniter, assigns) do
    router = assigns[:router]

    Edits.unless_contains(igniter, router, "FunWithFlags.UI.Router", fn igniter ->
      igniter
      |> Igniter.Libs.Phoenix.add_pipeline(
        :admin_tools,
        """
        plug :accepts, ["html"]
        plug :fetch_session
        plug :put_secure_browser_headers
        plug :load_from_session
        plug #{inspect(Module.concat([assigns[:web], "Plugs", "RequireAdmin"]))}
        """,
        router: router
      )
      |> Igniter.Libs.Phoenix.add_scope(
        "/admin/flags",
        """
        pipe_through :admin_tools

        forward "/", FunWithFlags.UI.Router, namespace: "admin/flags"
        """,
        router: router
      )
    end)
  end
end
