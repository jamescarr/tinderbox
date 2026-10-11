defmodule Tinderbox.Gen.Saas.Ops do
  @moduledoc """
  What it takes to run the application: health, metrics, tracing, mail, a release
  image and CI.

  * `GET /health` (`<App>Web.HealthController`): 200 while the database answers,
    503 otherwise; no session, CSRF or authentication,
  * PromEx: `<App>.PromEx`, `<App>.PromEx.Plugins.App` for the application's own
    metrics, its config, its supervisor child (first, so startup metrics are not
    missed) and `PromEx.Plug` ahead of the endpoint's request logging, serving
    `/metrics`,
  * OpenTelemetry: the Bandit, Phoenix, Ecto and Oban instrumentation is set up
    first thing in `Application.start/2`; traces are exported only when
    `OTEL_EXPORTER_OTLP_ENDPOINT` is set,
  * mail over SMTP (`SMTP_HOST`, `SMTP_PORT`) in every environment but test: Mailpit
    locally, and with `SMTP_USERNAME` set an authenticated, verified-STARTTLS relay,
  * `DATABASE_POOLER=pgbouncer` in production: unnamed prepared statements and
    Oban's PG notifier, for a database behind PgBouncer in transaction mode,
  * `mix phx.gen.release --docker`, run after the files are written: a release
    `Dockerfile`, `.dockerignore`, `<App>.Release` and the `bin/server`/`bin/migrate`
    overlays, from the toolchain that ran the generator,
  * `.github/workflows/ci.yml`, which installs Hex, fetches deps and runs
    `mise run check`,
  * `mix <app>.gen.domain` (`lib/mix/tasks/<app>.gen.domain.ex`): a new Ash domain
    through `ash.gen.domain`, registered in `ash_domains`, with its Oban queues,
  * `README.md`: how to run and configure the application, and the conventions
    the generated code follows (replacing Phoenix's stock README once),
  * the notice about the Stripe prerequisites.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits

  @otel_setup """
  OpentelemetryBandit.setup()
  OpentelemetryPhoenix.setup(adapter: :bandit)
  OpentelemetryEcto.setup([:%{app}, :repo])
  OpentelemetryOban.setup()
  """

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    igniter
    |> add_health(assigns)
    |> add_prom_ex(assigns)
    |> add_open_telemetry(assigns)
    |> add_mail(assigns)
    |> add_pooler(assigns)
    |> Igniter.add_task("phx.gen.release", ["--docker"])
    |> Igniter.create_new_file(
      ".github/workflows/ci.yml",
      Gen.render_template("saas/ops/ci.yml.eex", assigns)
    )
    |> add_domain_task(assigns)
    |> add_readme(assigns)
    |> add_notices(assigns[:opts])
  end

  # The task module is named after the OTP app, not the module prefix: Mix finds
  # `mix <app>.gen.domain` as `Mix.Tasks.<Macro.camelize(app)>.Gen.Domain`. Strings,
  # not aliases: `Gen` is this package's own module here.
  defp add_domain_task(igniter, assigns) do
    app = assigns[:app]

    task_module =
      inspect(Module.concat([Mix.Tasks, Macro.camelize(to_string(app)), "Gen", "Domain"]))

    Igniter.create_new_file(
      igniter,
      "lib/mix/tasks/#{app}.gen.domain.ex",
      Gen.render_template(
        "saas/ops/gen_domain_task.ex.eex",
        Keyword.put(assigns, :task_module, task_module)
      )
    )
  end

  # Phoenix's stock README is replaced once; a README that already mentions
  # `mise run dev` was written by an earlier run (or by hand) and is left alone.
  defp add_readme(igniter, assigns) do
    content = Gen.render_template("saas/README.md.eex", assigns)

    Igniter.create_or_update_file(igniter, "README.md", content, fn source ->
      if Rewrite.Source.get(source, :content) =~ "mise run dev" do
        source
      else
        Igniter.update_source(source, igniter, :content, content)
      end
    end)
  end

  # -- health ----------------------------------------------------------------

  defp add_health(igniter, assigns) do
    router = assigns[:router]

    igniter =
      Igniter.Project.Module.create_module(
        igniter,
        Module.concat(assigns[:web], "HealthController"),
        Gen.render_template("saas/ops/health_controller.ex.eex", assigns)
      )

    {igniter, present?} = Edits.source_contains?(igniter, router, "HealthController")

    igniter =
      if present? do
        igniter
      else
        # No `pipe_through`: the endpoint is probed by machines.
        Igniter.Libs.Phoenix.add_scope(
          igniter,
          "/",
          ~s(get "/health", HealthController, :show),
          arg2: assigns[:web],
          router: router
        )
      end

    exempt_health_from_force_ssl(igniter)
  end

  # Phoenix's `config/prod.exs` ships the exclusion commented out. A platform's
  # health check is plain HTTP, and `force_ssl` would redirect it to https.
  defp exempt_health_from_force_ssl(igniter) do
    exempted = ~r/^\s*paths: \["\/health"\],?$/m
    commented = ~r/^(\s*)# paths: \["\/health"\],$/m

    Edits.update_file(igniter, "config/prod.exs", fn content ->
      cond do
        Regex.match?(exempted, content) ->
          {:ok, content}

        Regex.match?(commented, content) ->
          {:ok, Regex.replace(commented, content, ~s(\\1paths: ["/health"],))}

        true ->
          {:warning,
           "config/prod.exs has no commented `paths: [\"/health\"]` in force_ssl's exclude; " <>
             "add it so a platform's plain-HTTP health check is not redirected to https."}
      end
    end)
  end

  # -- metrics ---------------------------------------------------------------

  defp add_prom_ex(igniter, assigns) do
    prom_ex = Module.concat(assigns[:prefix], "PromEx")

    igniter
    |> Igniter.Project.Module.create_module(
      prom_ex,
      Gen.render_template("saas/ops/prom_ex.ex.eex", assigns)
    )
    |> Igniter.Project.Module.create_module(
      Module.concat([assigns[:prefix], "PromEx", "Plugins", "App"]),
      Gen.render_template("saas/ops/prom_ex_plugin.ex.eex", assigns)
    )
    |> Igniter.Project.Config.configure(
      "config.exs",
      assigns[:app],
      [prom_ex],
      disabled: false,
      manual_metrics_start_delay: :no_delay,
      drop_metrics_groups: [],
      grafana: :disabled,
      metrics_server: :disabled
    )
    # No `after:`: Igniter then puts the child first in the list.
    |> Igniter.Project.Application.add_new_child(prom_ex)
    |> Edits.insert_before_plug(
      assigns[:endpoint],
      Plug.RequestId,
      "plug PromEx.Plug, prom_ex_module: #{inspect(prom_ex)}"
    )
  end

  # -- tracing ---------------------------------------------------------------

  defp add_open_telemetry(igniter, assigns) do
    app = assigns[:app]

    igniter
    |> Edits.prepend_to_start(
      Module.concat(assigns[:prefix], "Application"),
      String.replace(@otel_setup, "%{app}", to_string(app))
    )
    |> Gen.append_to_runtime_exs(
      Gen.render_template("saas/ops/otel_runtime.exs.eex", assigns),
      fn igniter ->
        Igniter.Project.Config.configures_root_key?(igniter, "runtime.exs", :opentelemetry)
      end
    )
  end

  # -- mail ------------------------------------------------------------------

  defp add_mail(igniter, assigns) do
    Gen.append_to_runtime_exs(
      igniter,
      Gen.render_template("saas/ops/mail_runtime.exs.eex", assigns),
      fn igniter -> runtime_contains?(igniter, "Swoosh.Adapters.SMTP") end
    )
  end

  defp add_pooler(igniter, assigns) do
    Gen.append_to_runtime_exs(
      igniter,
      Gen.render_template("saas/ops/pooler_runtime.exs.eex", assigns),
      fn igniter -> runtime_contains?(igniter, "DATABASE_POOLER") end
    )
  end

  # The SMTP config sits inside an `if`, which `configures_key?/4` does not look into.
  defp runtime_contains?(igniter, snippet) do
    if Igniter.exists?(igniter, "config/runtime.exs") do
      igniter = Igniter.include_existing_file(igniter, "config/runtime.exs")

      igniter.rewrite
      |> Rewrite.source!("config/runtime.exs")
      |> Rewrite.Source.get(:content)
      |> String.contains?(snippet)
    else
      false
    end
  end

  # -- notices ---------------------------------------------------------------

  # Where the Stripe settings go, and how to get the webhook secret, depend on
  # whether the project has mise (`.mise.local.toml`, `mise run stripe`) or only
  # compose (`.env`, the Stripe CLI by hand).
  defp add_notices(igniter, opts) do
    {file, listen} =
      if Keyword.get(opts, :mise, true) do
        {".mise.local.toml", "`mise run stripe`"}
      else
        {".env", "`stripe listen --forward-to localhost:4000/webhooks/stripe`"}
      end

    Igniter.add_notice(igniter, """
    Stripe: create two recurring Prices in your Stripe test-mode dashboard, put their ids and \
    your sk_test_… key in #{file} (STRIPE_PRICE_STARTER, STRIPE_PRICE_PRO, \
    STRIPE_SECRET_KEY), run #{listen} and copy the printed whsec_… into \
    STRIPE_WEBHOOK_SECRET. Until then /billing says Stripe is not configured.\
    """)
  end
end
