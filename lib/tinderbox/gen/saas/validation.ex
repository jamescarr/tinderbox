defmodule Tinderbox.Gen.Saas.Validation do
  @moduledoc """
  Measuring whether anyone wants the product, first-party and in Postgres:

  * `<App>.Analytics` — the Ash domain and the `track/3` facade, registered in
    `ash_domains`; `<App>.Analytics.Event` (table `analytics_events`, admins
    read); `<App>.Analytics.Changes.Track`, which records an event after an
    action commits (organizations record `organization.created` with it); and
    `<App>.Analytics.Funnel`, the dashboard's numbers against the thresholds in
    `<App>.Concept`,
  * `<App>.Waitlist` and `<App>.Waitlist.Signup` (table `waitlist_signups`):
    anyone joins, an email joins once, admins read,
  * `<App>Web.Plugs.Visitor` in the `:browser` pipeline: a random visitor id in
    a cookie, the `anonymous_id` that counts distinct visitors,
  * `<App>Web.PageController`, replacing Phoenix's stock one: every landing
    page view is a `landing.viewed` event with its campaign parameters,
  * `POST /waitlist` (`<App>Web.WaitlistController`), the landing page's form,
  * `GET /admin/waitlist.csv` (`<App>Web.Admin.WaitlistController`) behind the
    `:admin_tools` pipeline `Tinderbox.Gen.Saas.Flags` creates; the pages,
    `/admin/validation` and `/admin/waitlist`, are `Tinderbox.Gen.Saas.Admin`'s,
  * tests of the analytics and the funnel, the waitlist form and the dashboard.

  Sign-ins are recorded (`user.signed_in`) by `Tinderbox.Gen.Saas.Mfa`'s
  `MfaController`, where every sign-in ends.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    prefix = assigns[:prefix]
    analytics = Module.concat(prefix, "Analytics")
    waitlist = Module.concat(prefix, "Waitlist")

    igniter
    |> create_modules(analytics, waitlist, assigns)
    |> register_domain(analytics, assigns)
    |> register_domain(waitlist, assigns)
    |> replace_page_controller(assigns)
    |> add_routes(assigns)
    |> add_tests(assigns)
  end

  defp create_modules(igniter, analytics, waitlist, assigns) do
    web = assigns[:web]

    Gen.create_modules(
      igniter,
      [
        {analytics, "saas/validation/analytics.ex.eex"},
        {Module.concat(analytics, "Event"), "saas/validation/event.ex.eex"},
        {Module.concat([analytics, "Changes", "Track"]), "saas/validation/track.ex.eex"},
        {Module.concat(analytics, "Funnel"), "saas/validation/funnel.ex.eex"},
        {waitlist, "saas/validation/waitlist.ex.eex"},
        {Module.concat(waitlist, "Signup"), "saas/validation/signup.ex.eex"},
        {Module.concat([web, "Plugs", "Visitor"]), "saas/validation/visitor_plug.ex.eex"},
        {Module.concat(web, "WaitlistController"), "saas/validation/waitlist_controller.ex.eex"},
        {Module.concat([web, "Admin", "WaitlistController"]),
         "saas/admin/waitlist_controller.ex.eex"}
      ],
      assigns
    )
  end

  defp register_domain(igniter, domain, assigns) do
    Igniter.Project.Config.configure(
      igniter,
      "config.exs",
      assigns[:app],
      [:ash_domains],
      [domain],
      updater: &Igniter.Code.List.prepend_new_to_list(&1, domain)
    )
  end

  # Phoenix's stock controller only renders; the generated one also records the
  # view. A controller that already tracks (an earlier run, or the developer's)
  # is left alone.
  defp replace_page_controller(igniter, assigns) do
    Gen.replace_module(
      igniter,
      Module.concat(assigns[:web], "PageController"),
      Gen.render_template("saas/validation/page_controller.ex.eex", assigns),
      &(not String.contains?(&1, "Analytics"))
    )
  end

  defp add_routes(igniter, assigns) do
    router = assigns[:router]
    web = assigns[:web]
    visitor = inspect(Module.concat([web, "Plugs", "Visitor"]))

    igniter
    |> Edits.unless_contains(router, "Plugs.Visitor", fn igniter ->
      Igniter.Libs.Phoenix.append_to_pipeline(igniter, :browser, "plug #{visitor}",
        router: router
      )
    end)
    |> Edits.unless_contains(router, "WaitlistController, :create", fn igniter ->
      Igniter.Libs.Phoenix.append_to_scope(
        igniter,
        "/",
        ~s(post "/waitlist", WaitlistController, :create),
        with_pipelines: [:browser],
        arg2: web,
        router: router
      )
    end)
    |> Edits.unless_contains(router, "Admin.WaitlistController", fn igniter ->
      Igniter.Libs.Phoenix.add_scope(
        igniter,
        "/admin",
        """
        pipe_through :admin_tools

        get "/waitlist.csv", Admin.WaitlistController, :export
        """,
        arg2: web,
        router: router
      )
    end)
  end

  defp add_tests(igniter, assigns) do
    app = assigns[:app]

    [
      {"test/#{app}/analytics_test.exs", "saas/validation/analytics_test.exs.eex"},
      {"test/#{app}_web/controllers/waitlist_controller_test.exs",
       "saas/validation/waitlist_controller_test.exs.eex"},
      {"test/#{app}_web/live/admin/validation_live_test.exs",
       "saas/validation/validation_live_test.exs.eex"}
    ]
    |> Enum.reduce(igniter, fn {path, template}, igniter ->
      Igniter.create_new_file(igniter, path, Gen.render_template(template, assigns),
        on_exists: :skip
      )
    end)
  end
end
