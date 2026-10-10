defmodule Tinderbox.Gen.Saas.Admin do
  @moduledoc """
  The admin section at `/admin`, built with Petal Components.

  Every page requires a signed-in user with `role: :admin` (`<App>Web.LiveAdmin`):

  | Route | Page |
  |---|---|
  | `/admin` | counts of users, organizations and active subscriptions |
  | `/admin/users` | every user; grant or revoke the admin role |
  | `/admin/organizations` | every organization, with member count and plan |
  | `/admin/organizations/:id` | one organization: members, subscription, invitations |
  | `/admin/subscriptions` | every subscription synced from Stripe |

  The list pages are Petal's `<.data_table>` over an in-memory list. The feature
  flag dashboard at `/admin/flags` is `Tinderbox.Gen.Saas.Flags`.

  Admin pages `use <App>Web, :admin_live_view`, which this adds to the web module:
  Petal Components and CoreComponents both define `button/1`, `table/1`, `icon/1`
  and more, so the two sets never share a module.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits

  @live_views ~w(DashboardLive UsersLive OrganizationsLive OrganizationLive SubscriptionsLive)

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    igniter
    |> add_web_helpers(assigns)
    |> create_modules(assigns)
    |> add_routes(assigns)
  end

  defp add_web_helpers(igniter, assigns) do
    web = assigns[:web]
    {igniter, present?} = Edits.source_contains?(igniter, web, "def admin_live_view")

    if present? do
      igniter
    else
      {gettext?, igniter} =
        Igniter.Project.Module.module_exists(igniter, Module.concat(web, "Gettext"))

      Edits.append_to_module(
        igniter,
        web,
        Gen.render_template("saas/admin/web_helpers.ex.eex", [{:gettext?, gettext?} | assigns])
      )
    end
  end

  defp create_modules(igniter, assigns) do
    web = assigns[:web]

    igniter =
      Igniter.Project.Module.create_module(
        igniter,
        Module.concat([web, "Admin", "Layouts"]),
        Gen.render_template("saas/admin/layouts.ex.eex", assigns)
      )

    Enum.reduce(@live_views, igniter, fn name, igniter ->
      Igniter.Project.Module.create_module(
        igniter,
        Module.concat([web, "Admin", name]),
        Gen.render_template("saas/admin/#{Macro.underscore(name)}.ex.eex", assigns)
      )
    end)
  end

  defp add_routes(igniter, assigns) do
    router = assigns[:router]
    {igniter, present?} = Edits.source_contains?(igniter, router, ":admin_routes")

    if present? do
      igniter
    else
      Igniter.Libs.Phoenix.add_scope(
        igniter,
        "/admin",
        """
        pipe_through :browser

        ash_authentication_live_session :admin_routes do
          live "/", Admin.DashboardLive
          live "/users", Admin.UsersLive
          live "/organizations", Admin.OrganizationsLive
          live "/organizations/:id", Admin.OrganizationLive
          live "/subscriptions", Admin.SubscriptionsLive
        end
        """,
        arg2: assigns[:web],
        router: router
      )
    end
  end
end
