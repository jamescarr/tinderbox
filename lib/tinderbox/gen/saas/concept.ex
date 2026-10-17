defmodule Tinderbox.Gen.Saas.Concept do
  @moduledoc """
  What the business is, as data the application reads: the landing page's copy
  and pricing, the event that counts as activation, and the thresholds the
  validation dashboard judges the funnel against.

  * `<App>.Concept` (`lib/<app>/concept.ex`), with neutral defaults until
    `mix <app>.gen.concept` rewrites it from `concept.exs` (the template is the
    one that task renders, `priv/templates/<app>.gen/concept.ex.eex` in the
    project); the landing page and the app shell's brand (`Tinderbox.Gen.Saas.Web`)
    are drawn from it,
  * `concept.exs` at the project root: a documented starter manifest, already
    formatted (the project's formatter checks root `*.exs` files),
  * the browser tab in `root.html.heex`: `<page> · <name>` instead of Phoenix's
    `<page> · Phoenix Framework`, and the tagline for a page without a title.

  Each file is written once: a re-run keeps the project's own `concept.exs` and
  `<App>.Concept`.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits

  @tagline "Organizations, teammates and billing, ready to build on."

  # The landing page's three cards before there is a concept.
  @value_props [
    %{
      title: "Organizations",
      body: "Invite your team, give each person a role and switch between organizations.",
      icon: "hero-building-office-2"
    },
    %{
      title: "Billing",
      body: "Stripe subscriptions with checkout and a self-service billing portal.",
      icon: "hero-credit-card"
    },
    %{
      title: "Notifications",
      body: "An in-app inbox and email, with per-person settings for each kind of message.",
      icon: "hero-bell"
    }
  ]

  @thresholds [
    within_days: 30,
    visitors: nil,
    waitlist: nil,
    registered: nil,
    activated: nil,
    paying: nil
  ]

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    igniter
    |> create_concept_module(assigns)
    |> Igniter.create_new_file(
      "concept.exs",
      Gen.render_template("saas/concept/concept.exs.eex", assigns),
      on_exists: :skip
    )
    |> name_the_tab(assigns)
  end

  defp create_concept_module(igniter, assigns) do
    concept = Module.concat(assigns[:prefix], "Concept")

    case Igniter.Project.Module.module_exists(igniter, concept) do
      {true, igniter} ->
        igniter

      {false, igniter} ->
        Gen.create_modules(
          igniter,
          [{concept, "saas/gen/templates/concept.ex.eex"}],
          template_assigns(assigns)
        )
    end
  end

  # The template takes Elixir source for every value: `mix <app>.gen.concept`
  # renders the same file from the manifest.
  defp template_assigns(assigns) do
    [
      app: assigns[:app],
      name: inspect(inspect(assigns[:prefix])),
      tagline: inspect(@tagline),
      description: inspect(""),
      cta: inspect(:register),
      value_props: inspect(@value_props, limit: :infinity, printable_limit: :infinity),
      plans: inspect([]),
      activation_event: inspect("organization.created"),
      thresholds: map_source(@thresholds)
    ]
  end

  # `inspect/1` sorts a map's keys; the thresholds read in the manifest's order.
  defp map_source(pairs) do
    "%{" <> Enum.map_join(pairs, ", ", fn {key, value} -> "#{key}: #{inspect(value)}" end) <> "}"
  end

  # Phoenix titles every tab `<page> · Phoenix Framework`, and a page without a
  # title `<App> · Phoenix Framework`; these read `<page> · <name>` and
  # `<tagline> · <name>`, through `tab_suffix/0` and `tab_default/0` of the layouts
  # `Tinderbox.Gen.Saas.Web` writes (short calls: the root layout is not run through
  # the formatter here, and a longer `<.live_title>` would be one it breaks up).
  defp name_the_tab(igniter, assigns) do
    path = "lib/#{assigns[:app]}_web/components/layouts/root.html.heex"
    stock = ~s|default="#{inspect(assigns[:prefix])}" suffix=" · Phoenix Framework"|
    ours = "default={tab_default()} suffix={tab_suffix()}"
    layouts = Module.concat(assigns[:web], "Layouts")

    case Edits.source_contains?(igniter, layouts, "defp tab_suffix") do
      {igniter, true} ->
        Gen.update_file(igniter, path, fn content ->
          cond do
            String.contains?(content, ours) ->
              {:ok, content}

            String.contains?(content, stock) ->
              {:ok, String.replace(content, stock, ours)}

            true ->
              {:warning,
               "#{path} is not Phoenix's: set `#{ours}` on its <.live_title> to name the " <>
                 "browser tab after the concept."}
          end
        end)

      {igniter, false} ->
        igniter
    end
  end
end
