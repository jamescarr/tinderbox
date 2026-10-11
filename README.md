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
   organizations with memberships and invitations, notifications (in-app inbox and
   email), Stripe subscriptions, an admin area built with Petal Components, a JSON:API
   with OpenAPI docs, JetStream domain events, feature flags, health, metrics and
   tracing, a release `Dockerfile` and a CI workflow.

All stacks also get object storage (`<App>.Storage`) with two interchangeable
backends — `s3` through `ex_aws` and `gcs` through `Req` — both pointed at the local
emulators.

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
  --stack saas
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
| `--stack api\|worker\|saas` | installer | — (required) | which stack to generate |
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
real re-run was only seen to refuse, see below). `tinderbox.install` removes the
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
* **`[env]`** — the local environment: the emulator endpoints, `STORAGE_BACKEND`, and
  for the worker `HEALTH_PORT` plus the broker's variables. `.env.example` is rendered
  from the same data, so the two cannot drift.
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
  raises is nacked.
* **API** — AshJsonApi at `/api/json` and `/api` (organizations), OpenAPI at
  `/api/json/open_api`, Swagger UI at `/api/json/swaggerui`, bearer-token sign-in
  through the installer's `:api` pipeline. A request without a token gets `200` with
  an empty `data` list, not `403`: the installer configures Ash to filter instead of
  forbid.
* **Admin** — `/admin` (Petal Components): dashboard, users, organizations (and one
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

In production (the release image) the application refuses to start without
`DATABASE_URL`, `SECRET_KEY_BASE` and `TOKEN_SIGNING_SECRET` (AshAuthentication's;
`runtime.exs` raises when it is missing). Also set `PHX_HOST`, `PHX_SERVER=true`, the
`NATS_*`, `SMTP_*`, `STRIPE_*`, `SSO_*` and `ADMIN_EMAILS` values of `.mise.toml`.
Run migrations with the release's `bin/migrate`.

The LiveViews use Petal Components next to Phoenix's daisyUI core components.
`petal_components` pins `websock_adapter ~> 0.5.7` and never calls it, while Phoenix
locks 0.6.x, so the generator adds `{:websock_adapter, "~> 0.6", override: true}`.

### All stacks

* `docker-compose.yml` — Postgres, Floci (`:4566`, S3 + SQS), floci-gcp (`:4588`,
  GCS + Pub/Sub) and their bootstrap jobs, plus RabbitMQ, Redpanda or NATS (JetStream,
  `:4222`) for those brokers; the SaaS stack adds NATS, Dex (`:5556`) and Mailpit
  (SMTP `:1025`, UI `:8025`). A worker on `nats` also gets a `nats-bootstrap` job that
  creates its two streams and the consumer. The app itself runs on the host, so
  `FLOCI_HOSTNAME` is deliberately unset: Floci then embeds `localhost` in the SQS
  queue URLs and pre-signed URLs.
  A `ready` service depends on every bootstrap job completing: compose fails
  `up --wait` when a job merely exits, even with status 0, unless a running service
  is waiting for it. It runs under an init, because `sleep` as PID 1 ignores SIGTERM
  and `docker compose down` would otherwise wait out Docker's 10 s stop timeout.
* `.env.example` — the same variables as `[env]`, every line `export`ed.
* `.mise.toml` — see above.
* `.gitignore` — gains `.env` and `.mise.local.toml`.
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
  on the fresh project: formatting, warnings-as-errors compile and the five tests
  Phoenix generates. They are the only tests the project has; none cover the SaaS
  features. Under `mise run dev`, against compose (the first group on the generation
  before the last, which differs from the last only in how FunWithFlags starts, the
  formatting of the generated migration and a compile-warning pragma):
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

  On the last generation: SSO sign-in, creating an organization, the flag dashboard
  creating a flag that lands in `fun_with_flags_toggles`, `organization.create` and
  `membership.add` in the `<app>-events` stream and acked once each by
  `Events.Handler`, `/health` `200` and `/metrics` serving over a thousand `<app>_`
  series.

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

Not exercised: the untrusted-config path of `mise trust`. mise on the machine these
runs were made on never gated `.mise.toml` (a config with templates and hooks was
reported trusted too), so `mise trust` was a no-op there. It is left in the
instructions because mise refuses untrusted configs where it is set up to.

Not exercised for the SaaS stack: a real Stripe account (Checkout, the portal's plan
switch, `mise run stripe` — the Stripe CLI installs through mise and starts, but
`stripe listen` needs a login), a real OIDC issuer other than Dex, an SMTP server other
than Mailpit, a collector for the OpenTelemetry export, and the GitHub Actions
workflow.

If something else already owns 5432 on your machine, override the Postgres host port
in a `docker-compose.override.yml` (`ports: !override ["5455:5432"]`) and set the same
`port:` in `config/dev.exs` and `config/test.exs`.
