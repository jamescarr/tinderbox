# tinderbox

A tinderbox holds what you need to start a fire; this one holds what an Igniter
needs to catch. It is an [Igniter](https://hexdocs.pm/igniter) template: point
`mix igniter.new` at it and it scaffolds one of three Elixir stacks, plus the local
tooling to run it — an emulator-backed `docker-compose.yml`, the environment those
services need, and a `.mise.toml` that pins the toolchain and gives you the
dev-loop tasks.

1. **API stack** — Phoenix API-only + Ash + AshPostgres + AshJsonApi + AshPhoenix,
   with a working JSON:API resource reachable at `/api`.
2. **Worker stack** — headless OTP daemon: a Broadway pipeline that consumes from one
   messaging endpoint, records each message id in an Ash/AshPostgres idempotency store,
   and publishes the transformed message to a second endpoint of the same broker.
   Brokers: `sqs`, `pubsub`, `rabbitmq`, `kafka`, `nats`.
3. **SaaS stack** — a Phoenix LiveView application with password and SSO sign-in,
   two-factor authentication (TOTP, or the SSO provider's MFA),
   organizations with memberships and invitations, notifications (in-app inbox and
   email), Stripe subscriptions, an admin area, a JSON:API with OpenAPI docs and
   OAuth2 client-credentials connections for machines, JetStream domain events,
   feature flags, health, metrics and tracing, a release
   `Dockerfile` and a CI workflow — every page built on the themepack UI kit.

Separately, **`mix tinderbox.gen.ui`** adds that UI kit to any Phoenix LiveView
project (`--stack ui` on install): a themeable component library, an app shell
and a live component gallery at `/dev/ui`. See [UI kit](#ui-kit-mix-tinderboxgenui).

All stacks also get object storage (`<App>.Storage`) with two interchangeable
backends — `s3` through `ex_aws` and `gcs` through `Req` — both pointed at the local
emulators. It has `put/2`, `get/1`, `delete/1` and `presign/2` (S3 only: GCS needs a
service-account key to sign URLs and answers `{:error, :not_supported}`).

## Usage

```bash
# API stack
mix igniter.new my_api \
  --with phx.new \
  --with-args="--no-html --no-assets --no-live --no-dashboard --no-mailer --no-gettext" \
  --install tinderbox@path:/Users/jamescarr/projects/upmarkethq/tinderbox \
  --stack api

# Worker stack
mix igniter.new my_worker --sup \
  --install tinderbox@path:/Users/jamescarr/projects/upmarkethq/tinderbox \
  --stack worker --broker sqs

# SaaS stack (a full Phoenix app: keep phx.new's defaults)
mix igniter.new my_app \
  --with phx.new \
  --install tinderbox@path:/Users/jamescarr/projects/upmarkethq/tinderbox \
  --stack saas --themepack ember

# Only the UI kit, on a plain Phoenix app (no compose, no mise)
mix igniter.new my_app \
  --with phx.new \
  --install tinderbox@path:/Users/jamescarr/projects/upmarkethq/tinderbox \
  --stack ui --themepack harbor
```

`@path:…` installs from the working copy. To install from this repository instead,
swap the source (and drop the local path):

```bash
mix igniter.new my_worker --sup \
  --install tinderbox@github:jamescarr/tinderbox \
  --stack worker --broker sqs
```

### Running a generated project

With [mise](https://mise.jdx.dev) (the default):

```bash
mise trust && mise install   # once: allow .mise.toml, install Elixir + Erlang
mise run dev                 # start the services, set up the database, run the app
```

`mise run dev` is `up` → `setup` → `mix phx.server` (API, `http://localhost:4000/api`;
SaaS, `http://localhost:4000`, admin at `/admin`) or `mix run --no-halt` (worker,
`http://localhost:4001/health`).

Run bare `mix` commands through `mise exec -- mix …` when `.mise.local.toml` sets
anything: a plain shell does not load it, so `mix test` would reach for the default
ports. `mix ash.codegen` prints "this migration includes destructive operations" for
every migration whose `down/0` drops what its `up/0` creates, the first one included;
on a new resource that is expected.

Without mise:

```bash
docker compose up -d --wait
cp .env.example .env && . ./.env   # every line is exported; no `set -a` needed
mix ash.setup
mix phx.server                     # or: mix run --no-halt
```

### Flags

| Flag | Applies to | Default | Meaning |
|---|---|---|---|
| `--stack api\|worker\|saas\|ui` | installer | — (required) | which stack to generate; `ui` installs only the UI kit |
| `--themepack ember\|slate\|harbor` | saas, ui | `ember` | the UI kit's look; see [UI kit](#ui-kit-mix-tinderboxgenui) |
| `--broker sqs\|pubsub\|rabbitmq\|kafka\|nats` | worker | `sqs` | messaging technology for both the inbound consumer and the outbound publisher. The SaaS stack always runs on `nats` (JetStream) and ignores the flag |
| `--no-compose` | both | compose generated | skip `docker-compose.yml` / `.env.example` |
| `--no-mise` | both | mise generated | skip `.mise.toml` |
| `--no-demo` | api | demo generated | skip the demo `Catalog` domain + `Catalog.Item` resource |
| `--no-db` | `tinderbox.gen.compose`, `tinderbox.gen.mise` | Postgres service | skip the Postgres service and `DATABASE_URL` |

The individual tasks (`tinderbox.gen.api`, `.worker`, `.saas`, `.compose`, `.mise`) can
be re-run in an existing project. Re-running fails on the files a task *creates* —
compose, `.env.example`, `.mise.toml`, generated modules — rather than overwriting
them, and then writes nothing at all. The edits it makes to files that already exist
are guarded and not applied twice: dependencies, `config/runtime.exs`, `ash_domains`,
the supervisor children, `.gitignore`, and the `/api` mount in the router (the
guarded edits of the SaaS stack are covered by a test that applies it twice; the
real re-run was only seen to refuse, see below). `tinderbox.gen.ui` is the exception:
it skips kit modules that exist and is meant to be re-run, to switch packs.
`tinderbox.install` removes the
`tinderbox` path dependency from `mix.exs` when it finishes, because the path only
exists on the generating machine and `mix deps.get` fails anywhere else (CI first);
add it back for the run, as its notice says, before re-running a task.

## mise: toolchain, environment, tasks

Generated projects carry a `.mise.toml` (skip it with `--no-mise`):

* **`[tools]`** — Elixir and Erlang, pinned to the toolchain that ran the generator (for
  example `1.20.4-otp-29` and `29.1`). `mix new` writes the running Elixir's
  major.minor into `mix.exs` as its `elixir:` requirement, so a fixed pin would make
  `mise run dev` fail Mix's version check for anyone generating on another release
  (`phx.new` writes a fixed lower bound, which any newer Elixir satisfies). A dev or
  pre-release Elixir has no mise version: the pins then fall back to the pair this
  package was verified with, `1.20.4-otp-29` and `29.1`, and the generator prints a
  notice. The Kafka worker also pins CMake, because `brod`'s `crc32cer` NIF is built
  from source.
* **`[env]`** — the local environment: `PGPORT` (the host port compose publishes for
  Postgres, read by `config/dev.exs` and `config/test.exs`), the emulator endpoints,
  `STORAGE_BACKEND`, and for the worker `HEALTH_PORT` plus the broker's variables.
  `.env.example` is rendered from the same data, so the two cannot drift.
* **`[tasks.*]`**:

| Task | Does |
|---|---|
| `mise run up` | `docker compose up -d --wait` — returns once Postgres, the emulators and the bootstrap jobs are done |
| `mise run down` | `docker compose down` |
| `mise run setup` | `up`, then `mix deps.get` and `mix ash.setup` |
| `mise run dev` | `setup`, then the app |
| `mise run test` | `up`, then `mix test` |
| `mise run check` | `up`, then `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` |
| `mise run health` | worker only: `curl` the health endpoint on `$HEALTH_PORT` |
| `mise run stripe` | SaaS only: `stripe listen --forward-to localhost:4000/webhooks/stripe`; copy the printed `whsec_…` into `.mise.local.toml` as `STRIPE_WEBHOOK_SECRET` |

`--no-compose` leaves out `up`/`down` and the `depends` on them.

Tasks are inline tables, not `.mise/tasks/*` files: a file task has to be executable,
which files an igniter writes are not, and mise does not list a non-executable file
task until it has been run once.

**Machine-specific overrides** go in `.mise.local.toml` (gitignored; mise layers it
over `.mise.toml`). For example, when something else owns the default ports:

```toml
[env]
HEALTH_PORT = "4022"   # the worker reads it in config/runtime.exs
PORT = "4111"          # phx.new's runtime.exs reads it for the API
```

`DATABASE_URL` and `POOL_SIZE` are read by `MIX_ENV=prod` runs only; dev and test
take their Postgres settings from `config/dev.exs` and `config/test.exs`.

## What gets generated

### API stack (`mix tinderbox.gen.api`)

* `ash.install`, `ash_postgres.install`, `ash_json_api.install` — run by igniter, they
  create `<App>.Repo`, `<App>Web.AshJsonApiRouter`, the `:api` pipeline, and the
  `/api/json` mount (swagger UI at `/api/json/swaggerui`).
* `<App>.Catalog` + `<App>.Catalog.Item` — demo domain and resource (`items` table,
  unique `sku`), registered in `config :<app>, ash_domains:` and in the router's
  `domains:` list.
* `<App>Web.Router` — the AshJsonApi router is additionally mounted in an alias-free
  `scope "/api"` placed after the installer's `/api/json` scope, so
  `POST/GET/PATCH/DELETE /api/items` speak JSON:API and swagger stays reachable.
* `<App>.Storage` + the `:ex_aws`/`:storage` runtime config.

### Worker stack (`mix tinderbox.gen.worker`)

* `<App>.Inbox` + `<App>.Inbox.Message` — the idempotency store: one row per message
  id, unique identity on `message_id`, `processed_at` set only after the outbound
  publish succeeded.
* `<App>.Pipeline` — Broadway pipeline. Producer per broker:
  `BroadwaySQS.Producer` / `BroadwayCloudPubSub.Producer` / `BroadwayRabbitMQ.Producer`
  / `BroadwayKafka.Producer`. Duplicates (by `message_id`) are acked and skipped;
  failures are failed, leaving redelivery to the broker.
* `<App>.Processing` — the seam for real business logic: `handle/1` receives the
  decoded payload and returns the payload to publish.
* `<App>.Publisher` — outbound write: `ExAws.SQS` / Pub/Sub REST `:publish` /
  `AMQP` with publisher confirms / `:brod.produce_sync`. RabbitMQ and Kafka also get a
  connection process (`<App>.Publisher.Connection`, `<App>.Publisher.KafkaClient`)
  that is supervised before the pipeline.
* `<App>.Health` — `Plug.Router` serving `GET /health` (200 when the pipeline is
  alive, 503 otherwise), served by Bandit on `HEALTH_PORT`.

### SaaS stack (`mix tinderbox.gen.saas`)

Needs a Phoenix project with LiveView and assets (`mix igniter.new … --with phx.new`
with its default flags); it refuses one without. The generator installs and wires
`ash_authentication(_phoenix)`, `oban`, `ash_oban` and `ash_paper_trail` next to the
Ash packages the other stacks use, then adds:

* **Sign-in** — `<App>.Accounts.User` with a password strategy (bcrypt) and an SSO
  strategy over OpenID Connect (`SSO_BASE_URL`, `SSO_CLIENT_ID`, `SSO_CLIENT_SECRET`,
  `SSO_REDIRECT_URI`). Locally Dex issues the tokens (`docker/dex/config.yaml`,
  one static user, `admin@example.com` / `password`); register
  `<SSO_REDIRECT_URI>/user/sso/callback` with a real issuer. Users are `:user` or
  `:admin`: an email in `ADMIN_EMAILS` gets `:admin` when it registers. The list is
  empty in production unless you set it. The magic-link route the installer adds is
  removed.
* **Two-factor authentication** — for the two setups a SaaS meets: self-hosted TOTP,
  and an identity provider that already does MFA. People turn TOTP on at
  `/settings/security` (QR code, a confirming code, ten recovery codes shown once);
  sign-in then asks for a code at `/mfa` (`<App>Web.MfaController`) before anyone is
  signed in. Ten wrong codes in a row lock the factor for 15 minutes, a code is never
  accepted twice (the database settles concurrent requests), recovery codes are stored
  as SHA-256 hashes, and the TOTP secret is encrypted at rest (AshCloak, AES-GCM,
  `<App>.Vault`, keyed by `CLOAK_KEY`).
  Platform admins see everyone's status at `/admin/security` and can reset a user
  who lost the device and the codes. `MFA_REQUIRED=true` sends everyone without a
  factor to set one up at their next sign-in (and takes away the switch to turn it
  off); that enrolls whoever holds the password at that moment, so switch it on
  after the people who matter have enrolled. `MFA_SSO=idp` trusts the MFA the
  provider reports in the OIDC ID token (`amr`, or `acr` against `SSO_MFA_ACR`;
  `SSO_ACR_VALUES` asks the provider to step up, `urn:okta:loa:2fa:any` for Okta);
  an SSO sign-in without it falls back to the same code prompt, it is not refused.
  `<App>.Accounts.MFA` is the facade and `<App>.Accounts.MFA.Provider` the behaviour
  for another kind of factor. Only sign-ins finished by `<App>Web.AuthController` are
  gated: code that signs a user in some other way has to call
  `MFA.sign_in_step/2` too. A project generated before this existed gets it with
  `mix tinderbox.gen.mfa` (it adds `nimble_totp`, `eqrcode`, `cloak` and `ash_cloak`
  itself, creates an `add_mfa` migration, and replaces `AuthController` only while it
  is still the installer's).
* **Organizations** — `<App>.Accounts.Organization`, `Membership` (`owner`, `admin`,
  `member`) and `Invitation` (email, role, token link). The creator becomes the
  owner; the last owner cannot be removed or demoted. Re-inviting an address updates
  the open invitation instead of adding a row. Organizations, memberships,
  invitations and subscriptions keep a version history (`AshPaperTrail`); the
  invitation token is kept out of it.
* **Notifications** — `<App>.Notifications` with a catalog (`member.invited`,
  `member.joined`, `subscription.updated`, `payment.failed`), an in-app inbox at
  `/inbox` that updates live and a per-user email toggle at
  `/settings/notifications`. Email goes through an Oban job and Swoosh (SMTP to
  Mailpit locally, `SMTP_*` in production). `<App>.Notifications.Adapter` is the
  seam for another channel.
* **Billing** — `<App>.Billing` with `stripity_stripe`. Two plans from
  `STRIPE_PRICE_STARTER` and `STRIPE_PRICE_PRO`; `/billing` starts a Checkout
  session for an organization without a subscription and opens the Billing Portal
  for one that has one. Plan changes happen in the portal: a second Checkout for a
  subscribed organization is refused, because it would bill twice. Webhooks arrive at
  `/webhooks/stripe`, are verified against `STRIPE_WEBHOOK_SECRET` before the body
  is parsed, are stored once per event id, and an AshOban trigger fetches the
  subscription from Stripe and upserts the organization's single `subscriptions` row.
  A change of status notifies the organization's owners and admins.
* **Events** — `<App>.Events` over NATS JetStream: stream `<app>-events`, subjects
  `<app>.events.<type>`. Every create, update and destroy of an organization,
  membership, invitation or subscription is published as `<resource>.<action>` through
  an `Ash.Notifier`; `<App>.Events.Handler` is where consumers go. A handler that
  raises is nacked. The payload is the record's public attributes, so `public?` on
  an attribute also puts it on the event bus.
* **API** — AshJsonApi at `/api/json` and `/api` (organizations), OpenAPI at
  `/api/json/open_api`, Swagger UI at `/api/json/swaggerui`, bearer-token sign-in
  through the installer's `:api` pipeline. A request without a token gets `200` with
  an empty `data` list, not `403`: the installer configures Ash to filter instead of
  forbid.
* **API connections** — `/connections` lists an organization's OAuth2
  client-credentials connections (every member sees them); owners and admins create
  and revoke them. `<App>.Connections.Connection` records a client held by an
  authorization server that `OAUTH_PROVIDER` selects through
  `<App>.Connections.Provider`, the way `STORAGE_BACKEND` selects the storage
  backend: `hydra` (Ory Hydra, in compose at `:4444` tokens and `:4445` admin, keeping
  its clients in a `hydra` database on the compose Postgres; with `HYDRA_ADMIN_TOKEN`
  set it drives hosted Ory Network) or `auth0` (the Management API; a
  Machine-to-Machine application with `create:clients`, `delete:clients` and
  `create:client_grants`). Both adapters are always generated; the tests use an
  in-memory `fake` one. Dex cannot issue `client_credentials` tokens, which is why it
  stays for SSO only. The secret is shown once, on the page, and stored nowhere. A
  client asks the provider's token endpoint for a JWT access token with
  `audience=$OAUTH_AUDIENCE`; `<App>.Connections.Tokens` verifies it against the
  issuer's JWKS (OIDC discovery: `iss`, `aud`, `exp`, `nbf` and an asymmetric
  algorithm), and `<App>Web.Plugs.LoadConnection`, after the user's bearer token in
  the `:api` pipeline, makes the unrevoked connection behind it the Ash actor. A
  token that was not issued by `OAUTH_ISSUER` is left alone (the policies see no
  actor); one that was and is not valid, or whose connection is revoked, gets `401`
  and `WWW-Authenticate: Bearer error="invalid_token"`. Revoking deletes the client
  at the provider and marks the row, so a token that has not expired stops working
  on its next request. A connection has no scopes: it reads what the read policies
  allow it, and `<App>.Accounts.Organization` lets it read its own organization.
* **Admin** — `/admin` (the UI kit, in the app shell): dashboard, users, organizations (and one
  organization), subscriptions, and the FunWithFlags dashboard at `/admin/flags`.
  Only `:admin` users get in: anyone else is sent to the dashboard, the flag
  dashboard answers `404`, and an anonymous visitor goes to sign-in.
* **Feature flags** — FunWithFlags stored through `<App>.Repo`, cache busting over
  `<App>.PubSub`; users are actors and organizations are groups
  (`<App>.FeatureFlags`). Both packages are `runtime: false` dependencies and a
  `releases:` entry loads them: `FunWithFlags.Supervisor` starts in the application
  tree after `Phoenix.PubSub`, because left to itself FunWithFlags starts before the
  host application and gives up subscribing after five seconds.
* **Operations** — `GET /health` (`{"status":"ok"}`), PromEx metrics at `GET /metrics`
  (not authenticated: keep it off the public internet), OpenTelemetry for Phoenix,
  Ecto, Oban and Bandit (exports when `OTEL_EXPORTER_OTLP_ENDPOINT` is set),
  `Dockerfile` and `rel/` from `mix phx.gen.release --docker`, and
  `.github/workflows/ci.yml`, which installs Hex, fetches deps and runs
  `mise run check`.
* **For the code you add** — `<App>.Accounts.managers/1` (an organization's owners and
  admins, the recipients the billing and invitation notifications use);
  `<App>.Accounts.Changes.InheritOrganization` (copy `organization_id` from a parent
  record, as a plain change so the policy sees it),
  `<App>.Accounts.Validations.SameOrganization` (reject referenced ids that belong to
  another organization) and `<App>.Accounts.Changes.NotifyManagers` (notify the
  managers after the transaction commits; a failure is logged, never undoes the
  change);
  `<App>Web.LiveHelpers` (`find/4`, `report/3`, `manager?/1`, `error_message/1`,
  shared by the organization pages); a `:require_manager` hook in
  `<App>Web.LiveOrganization` for owner/admin-only pages; `Layouts.app` takes `wide`
  for pages made of tables and `current_page` to highlight its navigation entry;
  `<App>.PromEx.Plugins.App`, an empty PromEx plugin for
  the application's own metrics; `<App>.Fixtures` and
  `<App>Web.LiveTestHelpers.sign_in/2` in `test/support`, used by
  `test/<app>_web/live/members_live_test.exs`; `mix <app>.gen.domain`, which runs
  `ash.gen.domain`, registers the domain in `ash_domains` and adds its `--queues` to
  the Oban config; and a `README.md` in place of Phoenix's (running it,
  configuration, and these conventions), written once.

In production (the release image) the application refuses to start without
`DATABASE_URL`, `SECRET_KEY_BASE` and `TOKEN_SIGNING_SECRET` (AshAuthentication's;
`runtime.exs` raises when it is missing) and `CLOAK_KEY` (`openssl rand -base64 32`;
encrypts the two-factor secrets, so keep it). Also set `PHX_HOST`, `PHX_SERVER=true`, the
`NATS_*`, `SMTP_*`, `STRIPE_*`, `SSO_*`, `MFA_*`, `OAUTH_*` (and `HYDRA_*` or `AUTH0_*`) and
`ADMIN_EMAILS` values of `.mise.toml`.
Run migrations with the release's `bin/migrate`. With `SMTP_USERNAME` (and
`SMTP_PASSWORD`) set, mail is authenticated and upgraded with verified STARTTLS;
behind PgBouncer set `DATABASE_POOLER=pgbouncer` (unnamed prepared statements and
Oban's PG notifier); on an IPv6-only private network (Fly) set `NATS_INET6=true`.
`/health` is exempt from `force_ssl`, so a platform's plain-HTTP health check is not
redirected.

Every page uses the UI kit (`<App>Web.UI`, see below) next to Phoenix's daisyUI core
components; the stack applies the `--themepack` (default `ember`) before anything
else.

### UI kit (`mix tinderbox.gen.ui`)

Needs a Phoenix LiveView project with its Tailwind + daisyUI assets (`phx.new`'s
defaults); it refuses one without `assets/css/app.css`. It works on a plain
`phx.new` project and is part of the SaaS stack.

A **themepack** is a light and a dark daisyUI theme (colors, radii, density), font
stacks, and the shape of the app shell. All packs share one component kit:

| Pack | Shell | Look |
|---|---|---|
| `ember` (default) | sidebar | Warm orange on charcoal, medium density |
| `slate` | sidebar | Neutral grays with indigo, compact: dense tool UIs |
| `harbor` | top navigation | Blue and white, roomy |

The generator:

* replaces Phoenix's two stock themes in `assets/css/app.css` with the pack's,
  between `/* tinderbox:themepack … */` markers (the themes stay named `light` and
  `dark`, so Phoenix's theme toggle keeps working), and sets
  `config :<app>, <App>Web.UI, themepack: …, shell: …`;
* creates the kit, once — after that it is the project's code: `<App>Web.UI`
  (`use`d by `html_helpers/0`, so every template sees it), `.Components`
  (`page_header`, `card`, `stat_grid`, `badge`, `status_badge`, `alert`,
  `empty_state`, `description_list`, `tabs`, `modal`, `dropdown`, `avatar`, `feed`,
  `form_section`, `search_input`, `pagination`, `relative_time/1`,
  `format_datetime/1`), `.Shell` (`app_shell`, `nav_item`, `nav_section`,
  `user_menu`), `.DataTable` (searchable, sortable, paginated) and `.ListState`
  (the table's in-memory search/sort/paging state, with its test);
* mounts `<App>Web.UIGalleryLive` at `/dev/ui` inside Phoenix's dev-only scope:
  every component, live, in the current pack;
* on a plain project, replaces Phoenix's demo `Layouts.app` with one in the app
  shell (a customized layout is left alone, with a notice).

Switch packs by re-running it: `mix tinderbox.gen.ui --themepack slate` rewrites
only the themepack region of `app.css` and the config. Without `--themepack` the
installed pack is kept. Components style themselves only through daisyUI's semantic
colors and radii, so a pack restyles all of them, in light and dark.

### All stacks

* `docker-compose.yml` — Postgres (host port `$PGPORT`, default 5432), Floci (`:4566`,
  S3 + SQS), floci-gcp (`:4588`, GCS + Pub/Sub) and their bootstrap jobs, plus
  RabbitMQ, Redpanda or NATS (JetStream, `:4222`) for those brokers; the SaaS stack
  adds NATS, Dex (`:5556`), Ory Hydra (`:4444` tokens, `:4445` admin, with two
  one-shot jobs that create and migrate its database) and Mailpit (SMTP
  `$SMTP_PORT`, UI `$MAILPIT_UI_PORT`,
  default 1025 and 8025). A worker on `nats` also gets a `nats-bootstrap` job that
  creates its two streams and the consumer. The app itself runs on the host, so
  `FLOCI_HOSTNAME` is deliberately unset: Floci then embeds `localhost` in the SQS
  queue URLs and pre-signed URLs.
  A `ready` service depends on every bootstrap job completing: compose fails
  `up --wait` when a job merely exits, even with status 0, unless a running service
  is waiting for it. It runs under an init, because `sleep` as PID 1 ignores SIGTERM
  and `docker compose down` would otherwise wait out Docker's 10 s stop timeout.
* `.env.example` — the same variables as `[env]`, every line `export`ed.
* `.mise.toml` — see above.
* `config/dev.exs`, `config/test.exs` — the repo's `port:` reads `PGPORT`.
* `.gitignore` — gains `.env`, `docker-compose.override.yml` and `.mise.local.toml`.
* `config/runtime.exs` — appended, *outside* the `if config_env() == :prod` block, so
  it applies in every environment: `:ex_aws` (with the `AWS_ENDPOINT_URL` host/port
  override and `ExAws.Request.Req` as the HTTP client, which keeps hackney out),
  `:storage`, and — for the worker — `:pipeline` and `:health_port`. Every value has
  the compose default, so mix tasks that load it (`ash.codegen`, `ash.setup`, `test`)
  work before any environment is loaded.

## Broker matrix

| `--broker` | Client dep | Compose service | Inbound | Outbound |
|---|---|---|---|---|
| `sqs` | `broadway_sqs`, `ex_aws_sqs` | — (Floci) | `SQS_QUEUE_URL` | `SQS_PUBLISH_QUEUE_URL` |
| `pubsub` | `broadway_cloud_pub_sub` | — (floci-gcp) | `PUBSUB_SUBSCRIPTION` | `PUBSUB_TOPIC` |
| `rabbitmq` | `broadway_rabbitmq` | `rabbitmq` | `RABBITMQ_QUEUE` (bound to `RABBITMQ_EXCHANGE`) | `RABBITMQ_PUBLISH_QUEUE` via `RABBITMQ_ROUTING_KEY` |
| `kafka` | `broadway_kafka` (`:brod`) | `redpanda` | `KAFKA_CONSUMER_TOPIC` | `KAFKA_PRODUCER_TOPIC` |
| `nats` | `gnat` (`Gnat.Jetstream.PullConsumer`) | `nats` | `NATS_STREAM` + `NATS_CONSUMER` (durable, pull) | `NATS_PUBLISH_SUBJECT` |

One broker technology per worker, used for both directions. To consume from X and
publish to Y, generate with the consumer's broker and edit `<App>.Publisher`.

Notes per broker:

* **pubsub** — the producer talks to floci-gcp through `base_url` +
  `token_generator: {<App>.Pipeline, :emulator_token, []}`; Goth (and real GCP
  credentials) is only needed for real Pub/Sub.
* **rabbitmq** — `<App>.Publisher.Connection` declares the durable topic exchange, the
  outbound queue and their binding, and publishes with confirms, so `:ok` means
  RabbitMQ persisted the message.
* **kafka** — `broadway_kafka` builds brod's `crc32cer` NIF from source, so CMake
  >= 3.16 is needed to compile it (mise installs it for you).
* **nats** — streams live in the broker, not the app: the compose `nats-bootstrap` job
  creates `<app>-inbound` (subject `<app>.inbound`), `<app>-outbound` and the
  `<app>-worker` consumer. The publisher waits for JetStream's `PubAck`, and sends
  `message_id` as `Nats-Msg-Id` so a retry inside the stream's duplicate window is
  stored once.

## Tests

```bash
mise run check    # format, warnings-as-errors compile, tests
```

The generators are exercised through `Igniter.Test.test_project/1` against the
`Tinderbox.Gen.*` modules, and `mix tinderbox.install` is composed against a test
project to cover flag handling and the files and notices each flag combination
produces. What a test project cannot do is fetch the packages the tasks declare in
`installs:` or run their installers. The SaaS generator is therefore tested against
`test/fixtures/saas/`: the files Phoenix, Ash, AshAuthentication, AshOban and Oban's
installers wrote in a real project (`mix.exs`, router, endpoint, application, user
resource and the rest), with the `UserIdentity` resource that `ash.gen.resource`
would have created. It also checks that applying the generator twice changes none of
the files the installers wrote.

Beyond that, generated projects were run end to end against the emulators:

* **worker / sqs, through mise, installed from `@github:jamescarr/tinderbox`** —
  `mise run dev` (up → setup → run) came up healthy. A message sent to the inbound
  queue came out of the outbound queue with `processed_at` added; sending the same
  body again, under the same `mise run dev`, produced **no** second message, left
  `inbox_messages` at one processed row, and left the inbound queue empty. Setting
  `HEALTH_PORT` in `.mise.local.toml` moved the app to the new port; `mise run down`
  returned in under a second; `mise run check` passed.
* **storage** — `STORAGE_BACKEND=s3` round-trips through Floci (`aws s3 ls` sees the
  object) and `STORAGE_BACKEND=gcs` through floci-gcp; a missing key is
  `{:error, :not_found}` on both.
* **api** — `POST /api/items` returns `201 Created` with the JSON:API document,
  `GET /api/items` lists it, `/api/json/open_api` and `/api/json/swaggerui` still
  serve the OpenAPI document, and `mix compile --warnings-as-errors` is clean.
* **broker matrix** — `pubsub`, `rabbitmq` and `kafka` workers compile with
  `--warnings-as-errors`; the pubsub worker consumed a message published to
  `demo-pubsub-inbound` on floci-gcp and published the transformed payload (plus
  its `message_id` attribute) to `demo-pubsub-outbound`.
* **worker / nats** — a worker generated with `--broker nats` ran under
  `mise run dev`; `/health` answered `{"status":"ok"}`. The same JSON body (with an
  `id`) published twice to `<app>.inbound` left one message in `<app>-outbound`, with
  `processed_at` added, one processed row in `inbox_messages`, and the consumer with
  both deliveries acked (no pending, none redelivered). `mise run check` passed.
* **saas** — generated with `mix igniter.new … --with phx.new --install
  tinderbox@path:… --stack saas --yes` (about four minutes). `mise run check` passes
  on the fresh project: formatting, warnings-as-errors compile and seven tests, the
  five Phoenix generates and the generated members page test (the owner sees the
  invite form, a member does not); the generated tests cover no other SaaS feature.
  Under `mise run dev`, against compose (the first group on an earlier generation,
  which differed from the next one only in how FunWithFlags starts, the formatting
  of the generated migration and a compile-warning pragma):
  * password registration (it signs the user in) and SSO through Dex; the SSO user in
    `ADMIN_EMAILS` is an admin, a password user is not, and the SSO user gets no
    confirmation email;
  * an organization is created (the creator is its owner); inviting an address sends
    an email to Mailpit, the invitee registers, accepts and lands on the dashboard as
    a `member`;
  * `/admin`, `/admin/users`, `/admin/organizations` and `/admin/subscriptions`
    render for the admin; for a member `/admin` redirects and `/admin/flags` is
    `404`; anonymous `/admin` redirects to `/sign-in`;
  * `GET /api/organizations` without a token is `200` with an empty `data` list.

  On that next generation, before the shared helpers: SSO sign-in, creating an
  organization, the flag dashboard creating a flag that lands in
  `fun_with_flags_toggles`, `organization.create` and `membership.add` in the
  `<app>-events` stream and acked once each by `Events.Handler`, `/health` `200` and
  `/metrics` serving over a thousand `<app>_` series.

  On the latest generation (shared helpers, test support, ports from the
  environment): the install task removed the `tinderbox` path dependency from
  `mix.exs` and printed it; with `PGPORT=5456`, `SMTP_PORT=1027`,
  `MAILPIT_UI_PORT=8027` and `PORT=4112` in `.mise.local.toml` (this machine's 5432,
  1025 and 8025 belong to other projects), compose published Postgres on 5456 and
  Mailpit on 1027/8027 and `mise run check` passed against them. Pushed unchanged to
  a private repository, the generated `.github/workflows/ci.yml` passed (Hex, deps,
  `mise run check` with the seven tests, about twelve minutes on `ubuntu-latest`).
  On the generation just before it, which differed only in the members page's
  role-form id and two documentation comments, `/metrics` served 360 `<app>_` series
  with the empty `<App>.PromEx.Plugins.App`, `/health` was `200`, and throwaway tests
  showed `:require_manager` continuing for the owner, sending a member to
  `/dashboard` with an error flash and a user with no organization to
  `/organizations/new`, and `Accounts.managers/1` returning the owner and an admin
  but not a member. A worker generated the same way (`--stack worker --broker sqs`)
  got the `port:` line inside the repo's block in `config/dev.exs` and
  `config/test.exs` (both imported by `config.exs`) and passed `mise run check` with
  Postgres on `PGPORT=5457`.

  On an earlier generation, not repeated since: a live inbox row and badge update
  without a reload, the `member.joined` notification and email to the owner, the
  per-event email toggle persisting, a re-invite updating one row instead of adding
  one, the version rows AshPaperTrail writes (without the invitation token),
  `/api/json/open_api` listing the organization paths, and FunWithFlags connecting to
  PubSub on the first try.

  **Stripe was only exercised against
  [stripe-mock](https://github.com/stripe/stripe-mock), not Stripe itself** (on the
  generation before the last). The
  customer is created and its id stored on the organization, the Billing Portal URL
  comes back, and stripe-mock accepted the Checkout session parameters. It returns no
  Checkout `url`, so the redirect (and the "no checkout page" message for that case)
  was not seen. Signed webhooks were posted to `/webhooks/stripe`: a wrong signature
  is `400`; a valid `customer.subscription.created` is stored once (the same event id
  again adds no row), an unrelated event type is acknowledged and ignored, and the
  subscription was synced in 0.3 s into one `subscriptions` row (`starter`,
  `active`), with a `subscription.updated` notification and email; an
  `invoice.payment_failed` produced `payment.failed` the same way. For that, the
  organization's `stripe_customer_id` and `STRIPE_PRICE_STARTER` were set to the
  values of stripe-mock's fixture subscription.
* **saas release image** — `docker build` produced the image (`mix assets.deploy`,
  `mix release`) and the container booted against the compose services:
  `/health`, `/metrics` and `/sign-in` answered, and `FunWithFlags` toggled and
  persisted a flag through `bin/<app> rpc`. The image was built from a project whose
  `mix.exs` had been edited by hand to what the generator writes (a generated one has
  the same entries with `releases:` last in `project/0`). The release does not boot
  without `TOKEN_SIGNING_SECRET`.
* **saas re-run** — `mix tinderbox.gen.saas` in a generated project reports
  "File already exists" for each module it would create and writes nothing; the
  guarded edits are only covered by the test that applies the generator twice.
* **saas two-factor authentication** — a project generated from this branch
  (`mfa_demo`, ports from `.mise.local.toml` because other projects held 4222, 4566,
  4588 and 5556): `mise run check` passed (formatting, warnings-as-errors compile,
  38 tests, 25 of them the generated MFA tests: the facade and TOTP provider, the
  controller, the settings page). Under `mise run dev`, in a browser:
  * a password user turned TOTP on at `/settings/security` (QR code and manual key,
    a confirming code, ten recovery codes); the code was computed from the displayed
    key by a script, not by an authenticator app, and the QR code was not scanned;
  * sign out and in landed on `/mfa` with `/dashboard` sent back to `/sign-in`
    meanwhile; a wrong code gave the error and stayed, the right code signed in, a
    recovery code signed in once and was refused the second time;
  * a throwaway test sent one TOTP code, then one recovery code, through 20
    concurrent `MFA.verify/2` calls: each time one returned `:ok` and 19
    `{:error, :invalid_code}`; with the spent-code filter taken out of
    `Totp.record_success/3`, all 20 calls accepted the same TOTP code;
  * `/admin/security` as an `ADMIN_EMAILS` user listed the user as On with nine
    recovery codes; Reset (with its confirm dialog) turned it Off;
  * with `MFA_REQUIRED=true` a user without a factor was sent to `/mfa/setup` after the
    password, confirming showed the recovery codes, Continue signed in, and
    `/settings/security` had no turn-off form;
  * SSO through Dex with `MFA_SSO=idp`: with no factor the SSO sign-in completed, and
    with one it went to `/mfa`, because Dex sends no `amr`; so what was seen is the
    fallback to the local rules. A throwaway test of the `sso` strategy's `:register`
    action with an unsigned ID token carrying `amr: ["pwd","mfa"]` put that on the
    user, and with `MFA_SSO=idp` `sign_in_step/2` was `:complete` for the SSO sign-in
    and `:enroll` for a password one under `MFA_REQUIRED`;
  * with `SSO_ACR_VALUES=urn:okta:loa:2fa:any` the redirect to the provider carried
    `acr_values=urn%3Aokta%3Aloa%3A2fa%3Aany` next to `scope=openid+openid+profile+email`
    (Assent prepends `openid` to the strategy's scope);
  * `MIX_ENV=prod mix run -e ''` without `CLOAK_KEY` (everything else set) exited with
    `environment variable CLOAK_KEY is missing`.

  `mix tinderbox.gen.mfa` was run in a project generated from the commit before this
  one (`pre_mfa`, not `main`, which is behind it): it added the four packages to
  `mix.exs`, created the modules, `*_add_mfa.exs` (a `mfa_factors` table only) and the
  tests, put Security in the user menu and Two-factor in the admin navigation, and
  replaced `AuthController`. With the `tinderbox` dependency removed again,
  `mise run check` passed (38 tests); `/settings/security` rendered under
  `mise run dev`; running the task again exited 1 with
  `already exists: this project has multi-factor authentication`. Since the task only
  writes the packages to `mix.exs` (Igniter runs `mix deps.get` before the queued
  `ash.codegen`), a fresh `pre_mfa` run created `*_add_mfa.exs` without a
  `Cloak.Vault is not loaded` failure, and `mise run check` passed (38 tests).
  **Not exercised:** a real identity provider that sends `amr`/`acr` (Okta, Entra,
  Auth0, Keycloak), an authenticator app, concurrent guesses against the lockout, and
  the customized-`AuthController` warning outside the generator test.
* **saas `mix <app>.gen.domain`** — in a project generated from this branch
  (`saas_check`, ports as above),
  `mix saas_check.gen.domain SaasCheck.Upstreams --queues upstreams:5,dead_letters --yes`
  created `SaasCheck.Upstreams` (`use Ash.Domain, otp_app: :saas_check`), put it first
  in `ash_domains` and appended `upstreams: 5, dead_letters: 10` to the Oban queues
  (`default: 10, billing: 5, notifications: 10` kept). Run again with
  `--queues upstreams:9` it changed nothing; `--queues "bad name"` exited 1 with
  `Invalid --queues entry "bad name"` and changed nothing. `mise run check` then
  passed (7 tests). `MIX_ENV=prod mix compile --force --warnings-as-errors` compiled
  the task without igniter, and running it in prod exited 1 saying it needs igniter.
* **ui** — `mix igniter.new ui_plain --with phx.new --with-args="--no-ecto" --install
  tinderbox@path:… --stack ui --themepack harbor --yes`: format, warnings-as-errors
  compile (dev and prod, so no `~p"/dev/…"` slipped in) and 11 tests passed (Phoenix's
  five and the generated `ListStateTest`'s six), and the built CSS carries harbor's
  tokens. In a browser at `/dev/ui`: the topnav shell, searching, sorting (with
  `aria-sort` flipping) and paging the table, the modal opening and closing on Escape
  with focus moved in and back, tabs patching `?tab=`, and light/dark. Re-running
  `mix tinderbox.gen.ui --themepack slate` changed only `assets/css/app.css` and
  `config/config.exs`, and the gallery came up in the sidebar shell, whose drawer
  opens from the menu button and closes on the overlay at phone width. Phoenix's own
  landing page does not use `Layouts.app`, so it keeps its look.
* **saas on the UI kit** — generated with `--themepack ember` (and again with
  `slate`): no `petal` in `mix.exs` or `mix.lock`, 13 tests passed. Under
  `mix phx.server` (Postgres, Mailpit and NATS only, on other ports): the topnav
  landing page signed out; registration, creating an organization, inviting, the
  dashboard, members, inbox, notification settings and billing in the sidebar shell
  with the current page highlighted; `/admin` and its users (search, sort by
  Registered, Make admin), organizations → View and subscriptions pages; the flag
  dashboard; light and dark. SSO was not exercised in this run (another project held
  Dex's port); `ADMIN_EMAILS` made the password user an admin.
* **saas API connections** — generated as above (the generator's own tests plus
  `mise run check` on the fresh project, regenerated from the final templates: 22
  tests, among them three `ConnectionsLiveTest` and six `ApiConnectionsTest` cases
  that run on the `fake` provider; `MIX_ENV=prod mix compile --warnings-as-errors`
  is clean). With `ash` 3.36.0, which a fresh resolution now picks, generation stops
  in `mix ash.codegen` (`Multiple actions (2) with the name read` on
  `Accounts.UserIdentity`, which the AshAuthentication installer helper creates; `main`
  fails the same way), so that run pinned `{:ash, "== 3.35.0"}` and ran the three
  tasks the generator had queued by hand. Compose came up
  with `hydra` healthy and `hydra-db` / `hydra-migrate` exited 0, discovery answering
  `jwks_uri` `http://localhost:4444/.well-known/jwks.json`. Under `mise run dev`, in a
  browser: **API connections** in the sidebar, creating `CI` showed the client id,
  secret, token endpoint and audience once (dismissed with Done). `curl -u` against
  `:4444/oauth2/token` gave a JWT (`client_id`, `iss` `http://localhost:4444/`,
  `aud` `http://localhost:4000/api`); with it `GET /api/organizations` listed only that
  connection's organization (a second user's organization was absent), and
  `/admin/clients` listed the client. Revoking it on the page (confirm dialog) turned
  the row to Revoked without a button; the same token was answered `401`,
  `WWW-Authenticate: Bearer error="invalid_token"` and the JSON:API error body, a new
  token request with the old credentials was `invalid_client`, and the client was gone
  from Hydra. `GET /api/organizations` without a token stayed `200` with an empty
  `data`, and a signed-in user's bearer token still listed their organizations. After
  `mise run down && mise run up` a connection created before was still in Hydra and
  its token flow worked. Throwaway tests against that Hydra: a member's create is
  forbidden before the provider is called; an unreachable provider is reported on the
  name field; a second revoke is refused; a create whose row fails to write (unknown
  organization, as a platform admin) deletes the client it registered, which was run
  again on the regenerated project, along with a token from an issuer whose JWKS
  cannot be fetched, with nothing cached, being answered `401` in 45 ms. The other
  projects on this machine held 4222, 8222, 4566, 4588 and 5556, so those host ports
  were moved with a `docker-compose.override.yml` (and `NATS_PORT` in
  `.mise.local.toml`) instead of stopping them.
* **saas production config and building blocks** — a project generated from this
  branch (`tb_learn`, ports as above, against the compose services of another
  project) compiled with `--warnings-as-errors`, passed its 7 tests without the
  `after_transaction` hook warning, and had `paths: ["/health"]` uncommented in
  `config/prod.exs` and `type` in `<.button>`'s attribute list. `runtime.exs` read with
  `Config.Reader.read!(…, env: :prod)` gave `{:unnamed, Oban.Notifiers.PG, :always,
  :verify_peer, [:inet6, :binary]}` with `DATABASE_POOLER=pgbouncer`, `SMTP_USERNAME`
  and `NATS_INET6=true` set, and `{nil, nil, :never, nil, [:binary]}` without them.
  `Storage.put`, `presign(key, expires_in: 60, disposition: …)` and `delete` ran
  against Floci: the presigned URL answered `200`, body `hello` and the requested
  `Content-Disposition`; `get` after `delete` was `{:error, :not_found}` and a second
  `delete` `:ok`. `InheritOrganization`, `SameOrganization` and `NotifyManagers` are
  exercised by trust_manage's suite, which runs the same module bodies. No connection
  to a real SMTP relay, PgBouncer or Fly network was made.

Not exercised: the untrusted-config path of `mise trust`. mise on the machine these
runs were made on never gated `.mise.toml` (a config with templates and hooks was
reported trusted too), so `mise trust` was a no-op there. It is left in the
instructions because mise refuses untrusted configs where it is set up to.

Not exercised for the SaaS stack: a real Stripe account (Checkout, the portal's plan
switch, `mise run stripe` — the Stripe CLI installs through mise and starts, but
`stripe listen` needs a login), a real OIDC issuer other than Dex, an SMTP server other
than Mailpit, a collector for the OpenTelemetry export, and SSO with the app moved
off port 4000.

Not exercised for API connections: the `auth0` adapter (no tenant was at hand: its
requests follow the Management API's documented shapes only), and Hydra as hosted Ory
Network (`HYDRA_ADMIN_TOKEN`).

If something else already owns 5432, 1025 or 8025 on your machine, set `PGPORT`,
`SMTP_PORT` or `MAILPIT_UI_PORT` in `.mise.local.toml`: compose publishes
`${PGPORT:-5432}:5432` and friends, and `config/dev.exs` and `config/test.exs` read
`PGPORT`. To move the app off 4000, set `PORT` and `SSO_REDIRECT_URI` there and add
the new `…/auth/user/sso/callback` to `redirectURIs` in `docker/dex/config.yaml`,
which Dex reads as a file (it otherwise refuses the SSO callback as an unregistered
redirect URI). `docker-compose.override.yml` is gitignored for any other local
change to the services.
