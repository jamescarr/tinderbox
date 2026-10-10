defmodule Tinderbox.Gen.Saas.Notifications do
  @moduledoc """
  The in-house notification platform of the SaaS stack, behind a facade shaped
  like Knock so it can be replaced by it.

  * `<App>.Notifications` — the Ash domain *and* the facade (`trigger/3`,
    `feed/2`, `unread_count/1`, `mark_read/2`, `mark_all_read/1`, `archive/2`,
    `preferences/1`, `set_preference/4`), registered in `config :<app>, ash_domains`,
  * `Notification` and `Preference` resources (tables `notifications` and
    `notification_preferences`),
  * `Catalog` — the keys users can mute,
  * `Adapter` (behaviour) and `Adapters.Local`, which stores in-app notifications,
    applies per-key channel rules and enqueues email,
  * `Workers.SendEmail` — the Oban job that sends one email through the mailer,
    on a `notifications` queue added to `config :<app>, Oban, queues:`,
  * `<App>Web.LiveNotifications` — the `on_mount` hook behind the live unread badge,
  * `config :<app>, mail_from:` in `config/runtime.exs`.
  """

  alias Tinderbox.Gen

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    prefix = assigns[:prefix]
    notifications = Module.concat(prefix, "Notifications")

    igniter
    |> create_modules(notifications, assigns)
    |> register_domain(notifications, assigns)
    |> add_queue(assigns)
    |> Gen.append_to_runtime_exs(
      Gen.render_template("saas/notifications/runtime_config.exs.eex", assigns),
      fn igniter ->
        Igniter.Project.Config.configures_key?(
          igniter,
          "runtime.exs",
          assigns[:app],
          [:mail_from]
        )
      end
    )
  end

  defp create_modules(igniter, notifications, assigns) do
    modules = [
      {notifications, "notifications.ex.eex"},
      {Module.concat(notifications, "Notification"), "notification.ex.eex"},
      {Module.concat(notifications, "Preference"), "preference.ex.eex"},
      {Module.concat(notifications, "Catalog"), "catalog.ex.eex"},
      {Module.concat(notifications, "Adapter"), "adapter.ex.eex"},
      {Module.concat([notifications, "Adapters", "Local"]), "adapters/local.ex.eex"},
      {Module.concat([notifications, "Workers", "SendEmail"]), "send_email.ex.eex"},
      {Module.concat(assigns[:web], "LiveNotifications"), "live_notifications.ex.eex"}
    ]

    Enum.reduce(modules, igniter, fn {module, template}, igniter ->
      Igniter.Project.Module.create_module(
        igniter,
        module,
        Gen.render_template("saas/notifications/" <> template, assigns)
      )
    end)
  end

  defp register_domain(igniter, notifications, assigns) do
    Igniter.Project.Config.configure(
      igniter,
      "config.exs",
      assigns[:app],
      [:ash_domains],
      [notifications],
      updater: fn zipper -> Igniter.Code.List.prepend_new_to_list(zipper, notifications) end
    )
  end

  # Adds `notifications: 10` to the Oban queues the Oban installer configured,
  # keeping whatever else is there.
  defp add_queue(igniter, assigns) do
    Igniter.Project.Config.configure(
      igniter,
      "config.exs",
      assigns[:app],
      [Oban, :queues],
      [notifications: 10],
      updater: fn zipper ->
        Igniter.Code.Keyword.set_keyword_key(zipper, :notifications, 10, fn queue ->
          {:ok, queue}
        end)
      end
    )
  end
end
