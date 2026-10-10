defmodule Tinderbox.Gen.Saas.Ops do
  @moduledoc """
  What it takes to run the application: health, metrics, tracing, mail, a release
  image and CI.

  * `GET /health` (`<App>Web.HealthController`): 200 while the database answers,
    503 otherwise; no session, CSRF or authentication,
  * PromEx: `<App>.PromEx`, its config, its supervisor child (first, so
    startup metrics are not missed) and `PromEx.Plug` ahead of the endpoint's
    request logging, serving `/metrics`,
  * OpenTelemetry: the Bandit, Phoenix, Ecto and Oban instrumentation is set up
    first thing in `Application.start/2`; traces are exported only when
    `OTEL_EXPORTER_OTLP_ENDPOINT` is set,
  * mail over SMTP (`SMTP_HOST`, `SMTP_PORT`) in every environment but test: Mailpit
    locally,
  * `mix phx.gen.release --docker`, run after the files are written: a release
    `Dockerfile`, `.dockerignore`, `<App>.Release` and the `bin/server`/`bin/migrate`
    overlays, from the toolchain that ran the generator,
  * `.github/workflows/ci.yml`, which runs `mise run check`,
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
    |> Igniter.add_task("phx.gen.release", ["--docker"])
    |> Igniter.create_new_file(
      ".github/workflows/ci.yml",
      Gen.render_template("saas/ops/ci.yml.eex", assigns)
    )
    |> add_notices(assigns[:opts])
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
  end

  # -- metrics ---------------------------------------------------------------

  defp add_prom_ex(igniter, assigns) do
    prom_ex = Module.concat(assigns[:prefix], "PromEx")

    igniter
    |> Igniter.Project.Module.create_module(
      prom_ex,
      Gen.render_template("saas/ops/prom_ex.ex.eex", assigns)
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
