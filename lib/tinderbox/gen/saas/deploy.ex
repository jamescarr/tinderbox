defmodule Tinderbox.Gen.Saas.Deploy do
  @moduledoc """
  Where the application runs, chosen with `--deploy` (`fly`, the default, or
  `none`).

  With `fly`:

  * `fly.toml` — the app on Fly.io: the release image `mix phx.gen.release --docker`
    writes, `bin/migrate` as the release command (over `DIRECT_DATABASE_URL` when
    set, since PgBouncer's transaction mode cannot hold a migration's lock), the
    environment the runtime config reads (IPv6 for the private network,
    `DATABASE_POOLER=pgbouncer` for Managed Postgres, Tigris storage, Resend SMTP,
    NATS at `<app>-nats.internal`), an always-on machine and the `/health` check,
  * `fly/nats/fly.toml` — NATS JetStream as its own Fly app, on a volume, listening
    on the private network only,
  * the README's "Deploying to Fly.io" runbook and `mise run deploy` (with flyctl
    in `.mise.toml`), which `Tinderbox.Gen.Mise` and `Tinderbox.Gen.Saas.Ops`
    render from the same option.

  Secrets are never written: the runbook sets them with `flyctl secrets set`.
  """

  alias Tinderbox.Gen

  @targets ~w(fly none)

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    case target(assigns[:opts]) do
      "fly" -> fly(igniter, assigns)
      "none" -> igniter
    end
  end

  @doc """
  The `--deploy` target in `opts` (`"fly"` when absent). Raises on anything but
  `"fly"` and `"none"`.
  """
  @spec target(keyword() | nil) :: String.t()
  def target(opts) do
    case Keyword.get(opts || [], :deploy) || "fly" do
      target when target in @targets ->
        target

      other ->
        Mix.raise(~s|Unknown --deploy #{inspect(other)}. Must be "fly" or "none".|)
    end
  end

  defp fly(igniter, assigns) do
    igniter
    |> Igniter.create_new_file(
      "fly.toml",
      Gen.render_template("saas/deploy/fly.toml.eex", assigns),
      on_exists: :skip
    )
    |> Igniter.create_new_file(
      "fly/nats/fly.toml",
      Gen.render_template("saas/deploy/nats_fly.toml.eex", assigns),
      on_exists: :skip
    )
  end
end
