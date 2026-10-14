defmodule Tinderbox.Gen.Saas.Admin do
  @moduledoc """
  The admin section at `/admin`, built with the themepack UI kit (`<App>Web.UI`).

  Every page requires a signed-in user with `role: :admin` (`<App>Web.LiveAdmin`):

  | Route | Page |
  |---|---|
  | `/admin` | counts of users, organizations and active subscriptions |
  | `/admin/users` | every user; grant or revoke the admin role |
  | `/admin/organizations` | every organization, with member count and plan |
  | `/admin/organizations/:id` | one organization: members, subscription, invitations |
  | `/admin/subscriptions` | every subscription synced from Stripe |

  The list pages are the kit's `<.data_table>` over an in-memory list, searched,
  sorted and paged by `<App>Web.UI.ListState`. The feature flag dashboard at
  `/admin/flags` is `Tinderbox.Gen.Saas.Flags`.

  Admin pages are ordinary `use <App>Web, :live_view` LiveViews rendered in
  `<App>Web.Admin.Layouts`, the same app shell as the rest of the app with the
  admin navigation.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits

  @live_views ~w(DashboardLive UsersLive OrganizationsLive OrganizationLive SubscriptionsLive)

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    igniter
    |> create_modules(assigns)
    |> add_routes(assigns)
  end

  defp create_modules(igniter, assigns) do
    web = assigns[:web]

    Gen.create_modules(
      igniter,
      [
        {Module.concat([web, "Admin", "Layouts"]), "saas/admin/layouts.ex.eex"}
        | Enum.map(@live_views, fn name ->
            {Module.concat([web, "Admin", name]), "saas/admin/#{Macro.underscore(name)}.ex.eex"}
          end)
      ],
      assigns
    )
  end

  defp add_routes(igniter, assigns) do
    router = assigns[:router]

    Edits.unless_contains(igniter, router, ":admin_routes", fn igniter ->
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
    end)
  end
end
