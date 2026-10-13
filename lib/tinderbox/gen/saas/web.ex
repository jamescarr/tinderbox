defmodule Tinderbox.Gen.Saas.Web do
  @moduledoc """
  The web shell of the SaaS stack: the Petal Components assets, the layout, the
  landing page, the signed-in LiveViews and their routes.

  * Petal Components: the Tailwind `@source`/`@import` in `assets/css/app.css` and
    the component hooks in `assets/js/app.js` (both edited only when absent),
  * `type` in `<.button>`'s forwarded attributes in `core_components.ex`, so
    `<.button type="button">` does not submit its form (edited only when absent),
  * `<App>Web.Layouts.app/1` — navigation bar, organization switcher, user menu and
    the inbox badge, replacing Phoenix's demo layout (`flash_group/1` and
    `theme_toggle/1` are kept as generated),
  * the landing page and its test, which now invite a visitor to sign in,
  * LiveViews inside the installer's `ash_authentication_live_session`:
    `/dashboard`, `/organizations/new`, `/organizations/members`,
    `/invitations/:token`, `/inbox`, `/settings/notifications`, `/billing`,
    and `<App>Web.LiveHelpers`, what the organization-scoped ones share,
  * `POST /organizations/switch`, the organization switcher's target,
  * test support: `<App>.Fixtures` (users, organizations, memberships),
    `<App>Web.LiveTestHelpers.sign_in/2`, and a test of the members page that
    uses both.

  The signed-in pages use Phoenix's own CoreComponents (daisyUI); the admin
  section is the only part that uses Petal Components
  (`Tinderbox.Gen.Saas.Admin`).
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits

  @live_views ~w(DashboardLive OrganizationNewLive MembersLive InvitationLive InboxLive
                 NotificationSettingsLive BillingLive)

  @css_imports """
  @source "../../deps/petal_components/**/*.*ex";
  @source not "../../deps/petal_components/lib/petal_components/showcase";
  @import "../../deps/petal_components/assets/default.css";
  """

  @js_import ~s(import PetalComponents from "../../deps/petal_components/assets/js/petal_components")

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    igniter
    |> install_petal_css()
    |> install_petal_js()
    |> allow_button_type(assigns)
    |> replace_layouts(assigns)
    |> replace_landing_page(assigns)
    |> create_live_helpers(assigns)
    |> create_live_views(assigns)
    |> add_routes(assigns)
    |> add_test_support(assigns)
  end

  # -- Petal Components ------------------------------------------------------

  # Paths are relative to `assets/css/app.css`, like Phoenix's own
  # `@source "../../lib/<app>_web"`. Petal's README shows `../deps/…` because it
  # assumes the stylesheet is `assets/app.css`.
  defp install_petal_css(igniter) do
    Edits.update_file(igniter, "assets/css/app.css", fn content ->
      if String.contains?(content, "petal_components") do
        {:ok, content}
      else
        insert_after_tailwind_import(content)
      end
    end)
  end

  defp insert_after_tailwind_import(content) do
    case Regex.run(~r/^@import "tailwindcss".*\n/m, content, return: :index) do
      [{start, length}] ->
        {head, tail} = String.split_at(content, start + length)
        {:ok, head <> @css_imports <> tail}

      nil ->
        {:warning,
         "Could not find `@import \"tailwindcss\"` in assets/css/app.css. Add the Petal " <>
           "Components lines by hand:\n\n" <> @css_imports}
    end
  end

  defp install_petal_js(igniter) do
    Edits.update_file(igniter, "assets/js/app.js", fn content ->
      cond do
        String.contains?(content, "PetalComponents") ->
          {:ok, content}

        String.contains?(content, "hooks: {...colocatedHooks}") ->
          {:ok,
           content
           |> String.replace(
             ~s(import topbar from "../vendor/topbar"\n),
             ~s(import topbar from "../vendor/topbar"\n) <> @js_import <> "\n",
             global: false
           )
           |> String.replace(
             "hooks: {...colocatedHooks}",
             "hooks: {...colocatedHooks, ...PetalComponents}"
           )}

        true ->
          {:warning,
           "Could not find `hooks: {...colocatedHooks}` in assets/js/app.js. Import the Petal " <>
             "Components hooks and merge them in by hand:\n\n" <>
             @js_import <> "\n\nhooks: {...colocatedHooks, ...PetalComponents}"}
      end
    end)
  end

  # Phoenix's `<.button>` forwards a fixed list of attributes. Without `type` in
  # it, `<.button type="button">` is an undefined-attribute warning (an error
  # under `--warnings-as-errors`) and the button still submits its form.
  defp allow_button_type(igniter, assigns) do
    Edits.update_file(
      igniter,
      "lib/#{assigns[:app]}_web/components/core_components.ex",
      fn content ->
        include = "include: ~w(href navigate patch method download name value disabled)"

        cond do
          String.contains?(content, "name value disabled type)") ->
            {:ok, content}

          String.contains?(content, include) ->
            {:ok, String.replace(content, include, String.replace_suffix(include, ")", " type)"))}

          true ->
            {:warning,
             "Could not find <.button>'s :rest include list in core_components.ex; add `type` to " <>
               "it so <.button type=\"button\"> renders a non-submitting button."}
        end
      end
    )
  end

  # -- layout and landing page ----------------------------------------------

  # The layout, landing page and page test are overwritten once: a file that
  # already knows about `current_user` was generated by an earlier run (or
  # customized) and is left alone.
  defp replace_layouts(igniter, assigns) do
    layouts = Module.concat(assigns[:web], "Layouts")
    body = Gen.render_template("saas/web/layouts.ex.eex", assigns)

    case Igniter.Project.Module.find_module(igniter, layouts) do
      {:ok, {igniter, source, _zipper}} ->
        # Through the Elixir updater, not a plain file write: only then does the
        # project's formatter (with the HEEx plugin) run on the result.
        Igniter.update_elixir_file(igniter, source.path, fn zipper ->
          current = zipper |> Sourceror.Zipper.root() |> Sourceror.to_string()

          if String.contains?(current, "current_user") do
            {:ok, zipper}
          else
            {:ok,
             layouts |> module_source(body) |> Sourceror.parse_string!() |> Sourceror.Zipper.zip()}
          end
        end)

      {:error, igniter} ->
        Igniter.Project.Module.create_module(igniter, layouts, body)
    end
  end

  defp replace_landing_page(igniter, assigns) do
    app = assigns[:app]

    igniter
    |> replace_unless_current(
      "lib/#{app}_web/controllers/page_html/home.html.heex",
      Gen.render_template("saas/web/home.html.heex.eex", assigns)
    )
    |> replace_unless_current(
      "test/#{app}_web/controllers/page_controller_test.exs",
      Gen.render_template("saas/web/page_controller_test.exs.eex", assigns)
    )
  end

  defp replace_unless_current(igniter, path, content) do
    if Igniter.exists?(igniter, path) do
      Edits.update_file(igniter, path, fn current ->
        if String.contains?(current, "current_user") or current == content do
          {:ok, current}
        else
          {:ok, content}
        end
      end)
    else
      Igniter.create_new_file(igniter, path, content)
    end
  end

  # The template is a module body, like every other; this wraps it for the one
  # place a whole file is written over an existing one.
  defp module_source(module, body) do
    "defmodule #{inspect(module)} do\n#{body}\nend\n"
  end

  # -- LiveViews and routes --------------------------------------------------

  defp create_live_helpers(igniter, assigns) do
    Igniter.Project.Module.create_module(
      igniter,
      Module.concat(assigns[:web], LiveHelpers),
      Gen.render_template("saas/web/live_helpers.ex.eex", assigns)
    )
  end

  defp create_live_views(igniter, assigns) do
    Enum.reduce(@live_views, igniter, fn name, igniter ->
      Igniter.Project.Module.create_module(
        igniter,
        Module.concat(assigns[:web], name),
        Gen.render_template("saas/web/live/#{Macro.underscore(name)}.ex.eex", assigns)
      )
    end)
  end

  defp add_routes(igniter, assigns) do
    igniter
    |> add_live_routes(assigns)
    |> add_switch_route(assigns)
  end

  # Into the installer's (so far empty) `ash_authentication_live_session`, whose
  # `on_mount` chain the LiveViews extend themselves.
  defp add_live_routes(igniter, assigns) do
    router = assigns[:router]

    {igniter, present?} =
      Edits.source_contains?(igniter, router, ~s(live "/dashboard", DashboardLive))

    if present? do
      igniter
    else
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        with {:ok, zipper} <-
               Igniter.Code.Common.move_to(zipper, fn candidate ->
                 Igniter.Code.Function.function_call?(
                   candidate,
                   :ash_authentication_live_session,
                   [
                     1,
                     2,
                     3,
                     4
                   ]
                 )
               end),
             {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper) do
          {:ok, Igniter.Code.Common.add_code(zipper, live_routes())}
        else
          _ ->
            {:warning,
             "Could not find `ash_authentication_live_session` in #{inspect(router)}. " <>
               "Add these routes inside it by hand:\n\n" <> live_routes()}
        end
      end)
    end
  end

  defp live_routes do
    """
    live "/dashboard", DashboardLive
    live "/organizations/new", OrganizationNewLive
    live "/organizations/members", MembersLive
    live "/invitations/:token", InvitationLive
    live "/inbox", InboxLive
    live "/settings/notifications", NotificationSettingsLive
    live "/billing", BillingLive
    """
  end

  # A plain controller route: a LiveView cannot write the session the chosen
  # organization is kept in.
  defp add_switch_route(igniter, assigns) do
    router = assigns[:router]
    {igniter, present?} = Edits.source_contains?(igniter, router, "OrganizationController")

    if present? do
      igniter
    else
      Igniter.Libs.Phoenix.append_to_scope(
        igniter,
        "/",
        ~s(post "/organizations/switch", OrganizationController, :switch),
        with_pipelines: [:browser],
        arg2: assigns[:web],
        router: router
      )
    end
  end

  # -- test support ----------------------------------------------------------

  # `test/support` is in Phoenix's `elixirc_paths(:test)`; `:test_support` drops
  # the app prefix, so `<App>.Fixtures` lands in `test/support/fixtures.ex`.
  defp add_test_support(igniter, assigns) do
    igniter
    |> Igniter.Project.Module.create_module(
      Module.concat(assigns[:prefix], "Fixtures"),
      Gen.render_template("saas/test/fixtures.ex.eex", assigns),
      location: :test_support
    )
    |> Igniter.Project.Module.create_module(
      Module.concat(assigns[:web], "LiveTestHelpers"),
      Gen.render_template("saas/test/live_test_helpers.ex.eex", assigns),
      location: :test_support
    )
    |> Igniter.create_new_file(
      "test/#{assigns[:app]}_web/live/members_live_test.exs",
      Gen.render_template("saas/test/members_live_test.exs.eex", assigns)
    )
  end
end
