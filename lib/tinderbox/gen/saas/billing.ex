defmodule Tinderbox.Gen.Saas.Billing do
  @moduledoc """
  Stripe subscriptions for organizations: Checkout to subscribe, the Billing
  Portal to manage, and webhooks to keep the subscription in sync.

  * `<App>.Billing` — the Ash domain and facade (`start_checkout/3`,
    `portal_url/1`, `subscription/1`), registered in `config :<app>, ash_domains`,
  * `<App>.Billing.Plans` — the plans, read from `config :<app>, :plans`,
  * `<App>.Billing.Subscription` — one synced subscription per organization,
  * `<App>.Billing.StripeEvent` — a recorded webhook event whose AshOban trigger
    (`:sync`, queue `billing`) fetches the subscription from Stripe and upserts it,
  * `<App>.Billing.Changes.SyncSubscription` — that sync,
  * `<App>Web.StripeWebhookHandler` + `Stripe.WebhookPlug` at `/webhooks/stripe`,
    mounted in the endpoint *before* `Plug.Parsers` (the signature is computed
    over the raw body),
  * runtime config: plans, webhook secret, `stripe_configured?`, the Stripe API key.
  """

  alias Tinderbox.Gen
  alias Tinderbox.Gen.Saas.Edits

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    billing = Module.concat(assigns[:prefix], "Billing")

    igniter
    |> create_modules(billing, assigns)
    |> register_domain(billing, assigns)
    |> add_queue(assigns)
    |> add_runtime_config(assigns)
    |> mount_webhook(assigns)
  end

  defp create_modules(igniter, billing, assigns) do
    modules = [
      {billing, "billing.ex.eex"},
      {Module.concat(billing, "Plans"), "plans.ex.eex"},
      {Module.concat(billing, "Subscription"), "subscription.ex.eex"},
      {Module.concat(billing, "StripeEvent"), "stripe_event.ex.eex"},
      {Module.concat([billing, "Changes", "SyncSubscription"]),
       "changes/sync_subscription.ex.eex"},
      {Module.concat(assigns[:web], "StripeWebhookHandler"), "stripe_webhook_handler.ex.eex"}
    ]

    Enum.reduce(modules, igniter, fn {module, template}, igniter ->
      Igniter.Project.Module.create_module(
        igniter,
        module,
        Gen.render_template("saas/billing/" <> template, assigns)
      )
    end)
  end

  defp register_domain(igniter, billing, assigns) do
    Igniter.Project.Config.configure(
      igniter,
      "config.exs",
      assigns[:app],
      [:ash_domains],
      [billing],
      updater: fn zipper -> Igniter.Code.List.prepend_new_to_list(zipper, billing) end
    )
  end

  # The AshOban trigger runs on its own `billing` queue.
  defp add_queue(igniter, assigns) do
    Igniter.Project.Config.configure(
      igniter,
      "config.exs",
      assigns[:app],
      [Oban, :queues],
      [billing: 5],
      updater: fn zipper ->
        Igniter.Code.Keyword.set_keyword_key(zipper, :billing, 5, fn queue -> {:ok, queue} end)
      end
    )
  end

  defp add_runtime_config(igniter, assigns) do
    Gen.append_to_runtime_exs(
      igniter,
      Gen.render_template("saas/billing/runtime_config.exs.eex", assigns),
      fn igniter ->
        Igniter.Project.Config.configures_key?(igniter, "runtime.exs", assigns[:app], [:plans])
      end
    )
  end

  # `secret:` is an MFA, not a value: the endpoint is compiled before
  # `config/runtime.exs` runs, so the secret has to be read at request time.
  defp mount_webhook(igniter, assigns) do
    Edits.insert_before_plug(igniter, assigns[:endpoint], Plug.Parsers, """
    plug Stripe.WebhookPlug,
      at: "/webhooks/stripe",
      handler: #{inspect(Module.concat(assigns[:web], "StripeWebhookHandler"))},
      secret: {Application, :get_env, [#{inspect(assigns[:app])}, :stripe_webhook_secret]}
    """)
  end
end
