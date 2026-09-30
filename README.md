# tinderbox

A tinderbox holds what you need to start a fire; this one holds what an Igniter
needs to catch. It is an [Igniter](https://hexdocs.pm/igniter) template: point
`mix igniter.new` at it and it scaffolds one of two Elixir stacks, plus the local
tooling to run it — an emulator-backed `docker-compose.yml`, the environment those
services need, and a `.mise.toml` that pins the toolchain and gives you the
dev-loop tasks.

1. **API stack** — Phoenix API-only + Ash + AshPostgres + AshJsonApi + AshPhoenix,
   with a working JSON:API resource reachable at `/api`.
2. **Worker stack** — headless OTP daemon: a Broadway pipeline that consumes from one
   messaging endpoint, records each message id in an Ash/AshPostgres idempotency store,
   and publishes the transformed message to a second endpoint of the same broker.
   Brokers: `sqs`, `pubsub`, `rabbitmq`, `kafka`.

Both stacks also get object storage (`<App>.Storage`) with two interchangeable
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

`mise run dev` is `up` → `setup` → `mix phx.server` (API, `http://localhost:4000/api`)
or `mix run --no-halt` (worker, `http://localhost:4001/health`).

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
| `--stack api\|worker` | installer | — (required) | which stack to generate |
| `--broker sqs\|pubsub\|rabbitmq\|kafka` | worker | `sqs` | messaging technology for both the inbound consumer and the outbound publisher |
| `--no-compose` | both | compose generated | skip `docker-compose.yml` / `.env.example` |
| `--no-mise` | both | mise generated | skip `.mise.toml` |
| `--no-demo` | api | demo generated | skip the demo `Catalog` domain + `Catalog.Item` resource |
| `--no-db` | `tinderbox.gen.compose`, `tinderbox.gen.mise` | Postgres service | skip the Postgres service and `DATABASE_URL` |

The individual tasks (`tinderbox.gen.api`, `.worker`, `.compose`, `.mise`) can be
re-run in an existing project. Re-running fails on the files a task *creates* —
compose, `.env.example`, `.mise.toml`, generated modules — rather than overwriting
them. The edits it makes to files that already exist are guarded and not applied
twice: dependencies, `config/runtime.exs`, `ash_domains`, the supervisor children,
`.gitignore`, and the `/api` mount in the router.

## mise: toolchain, environment, tasks

Generated projects carry a `.mise.toml` (skip it with `--no-mise`):

* **`[tools]`** — Elixir `1.20.4-otp-29` and Erlang `29.1`, the pins ankusa uses (a
  test keeps them equal to this package's own `.mise.toml`). The Kafka worker also
  pins CMake, because `brod`'s `crc32cer` NIF is built from source.
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

### Both stacks

* `docker-compose.yml` — Postgres, Floci (`:4566`, S3 + SQS), floci-gcp (`:4588`,
  GCS + Pub/Sub) and their bootstrap jobs, plus RabbitMQ or Redpanda for those
  brokers. The app itself runs on the host, so `FLOCI_HOSTNAME` is deliberately
  unset: Floci then embeds `localhost` in the SQS queue URLs and pre-signed URLs.
  A `ready` service depends on every bootstrap job completing: compose fails
  `up --wait` when a job merely exits, even with status 0, unless a running service
  is waiting for it.
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

## Tests

```bash
mise run check    # format, warnings-as-errors compile, tests
```

The generators are exercised through `Igniter.Test.test_project/1` against the
`Tinderbox.Gen.*` modules, and `mix tinderbox.install` is composed against a test
project to cover flag handling and the files and notices each flag combination
produces. What a test project cannot do is fetch the packages the tasks declare in
`installs:`.

Beyond that, generated projects were run end to end against the emulators:

* **worker / sqs, through mise** — `mise run dev` (up → setup → run) came up healthy;
  a message sent to the inbound queue came out of the outbound queue with
  `processed_at` added; re-sending the same body produced **no** second message and
  left `inbox_messages` at one row. Overriding `HEALTH_PORT` in `.mise.local.toml`
  moved the app to the new port, and `mise run check` passed.
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

If something else already owns 5432 on your machine, override the Postgres host port
in a `docker-compose.override.yml` (`ports: !override ["5455:5432"]`) and set the same
`port:` in `config/dev.exs` and `config/test.exs`.
