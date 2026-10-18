defmodule Tinderbox.Gen.Saas.Generators do
  @moduledoc """
  The project's own generators. The `tinderbox` dependency is removed once the
  project is generated, so whatever a business needs to grow its domain afterwards
  is written into the project:

  | Task | What it adds |
  |---|---|
  | `mix <app>.gen.domain` | an Ash domain, registered in `ash_domains`, with its Oban queues |
  | `mix <app>.gen.resource` | an organization-scoped Ash resource (`name:type[:required][:unique]` attributes), its fixture and migration |
  | `mix <app>.gen.live` | the resource's list, show and form pages, routes, navigation entry and test (and the resource, when new) |
  | `mix <app>.gen.concept` | `concept.exs` applied: `<App>.Concept` rewritten, its resources generated |

  * `lib/mix/tasks/<app>.gen.*.ex` — the tasks, each defined only where Igniter is
    (dev and test) and a `Mix.raise` elsewhere, so production compiles them clean,
  * `lib/mix/<app>_gen.ex` — `Mix.<App>.Gen`, what the tasks share without Igniter:
    the attribute grammar, names, sample values, template assigns,
  * `priv/templates/<app>.gen/*.eex` — the files the tasks render (copied
    verbatim, one EEx level, evaluated in the project): the project's to edit.

  Each task module is named after the OTP app, not the module prefix: Mix finds
  `mix <app>.gen.resource` as `Mix.Tasks.<Macro.camelize(app)>.Gen.Resource`.
  """

  alias Tinderbox.Gen

  @templates ~w(resource.ex.eex index_live.ex.eex show_live.ex.eex form_live.ex.eex
                live_test.exs.eex fixture.ex.eex nav_item.heex.eex concept.ex.eex)

  @tasks [
    {"domain", "saas/gen/gen_domain_task.ex.eex"},
    {"resource", "saas/gen/gen_resource_task.ex.eex"},
    {"live", "saas/gen/gen_live_task.ex.eex"},
    {"concept", "saas/gen/gen_concept_task.ex.eex"}
  ]

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    app = assigns[:app]
    assigns = Keyword.merge(assigns, names(app))

    igniter
    |> Igniter.create_new_file(
      "lib/mix/#{app}_gen.ex",
      Gen.render_template("saas/gen/gen_support.ex.eex", assigns),
      on_exists: :skip
    )
    |> create_tasks(assigns)
    |> copy_templates(app)
  end

  # Strings, not aliases: `Gen` is this package's own module here.
  defp names(app) do
    camel = Macro.camelize(to_string(app))
    task = &inspect(Module.concat([Mix.Tasks, camel, "Gen", &1]))

    [
      support_module: inspect(Module.concat([Mix, camel, "Gen"])),
      # `task_module` is the name `gen_domain_task.ex.eex` has always used.
      task_module: task.("Domain"),
      domain_task: task.("Domain"),
      resource_task: task.("Resource"),
      live_task: task.("Live"),
      concept_task: task.("Concept")
    ]
  end

  defp create_tasks(igniter, assigns) do
    app = assigns[:app]

    Enum.reduce(@tasks, igniter, fn {name, template}, igniter ->
      Igniter.create_new_file(
        igniter,
        "lib/mix/tasks/#{app}.gen.#{name}.ex",
        Gen.render_template(template, assigns),
        on_exists: :skip
      )
    end)
  end

  defp copy_templates(igniter, app) do
    Enum.reduce(@templates, igniter, fn name, igniter ->
      Igniter.create_new_file(
        igniter,
        "priv/templates/#{app}.gen/#{name}",
        File.read!(Gen.template_path("saas/gen/templates/#{name}")),
        on_exists: :skip
      )
    end)
  end
end
