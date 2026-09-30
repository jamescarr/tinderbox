# tinderbox

Igniter template for two Elixir stacks. Point it at a fresh project with
`mix igniter.new` and it scaffolds the stack, its emulator-backed `docker-compose.yml`,
and the `.env.example` those services need.

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

Then, in the generated project:

```bash
docker compose up -d --wait
cp .env.example .env && source .env
mix ash.setup        # codegen + migrate + seed
mix phx.server       # api:  JSON:API on http://localhost:4000/api
mix run --no-halt    # worker: health on http://localhost:4001/health
```

### Flags

| Flag | Applies to | Default | Meaning |
|---|---|---|---|
| `--stack api\|worker` | installer | — (required) | which stack to generate |
| `--broker sqs\|pubsub\|rabbitmq\|kafka` | worker | `sqs` | messaging technology for both the inbound consumer and the outbound publisher |
| `--no-compose` | both | compose generated | skip `docker-compose.yml` / `.env.example` |
| `--no-demo` | api | demo generated | skip the demo `Catalog` domain + `Catalog.Item` resource |
| `--no-db` | `tinderbox.gen.compose` | Postgres service | skip the Postgres service and `DATABASE_URL` |

The individual tasks can be re-run in an existing project (`mix tinderbox.gen.compose
--stack worker --broker kafka`); each one guards its edits, so re-running is a no-op
except for module creation, which errors rather than silently clobbering a file.

## What gets generated

### API stack (`mix tinderbox.gen.api`)

* `ash.install`, `ash_postgres.install`, `ash_json_api.install` — run by igniter, they
  create `<App>.Repo`, `<App>Web.AshJsonApiRouter`, the `:api` pipeline, and the
  `/api/json` mount (swagger UI at `/api/json/swaggerui`).
* `<App>.Catalog` + `<App>.Catalog.Item` — demo domain and resource (`items` table,
  unique `sku`), registered in `config :<app>, ash_domains:` and in the router's
  `domains:` list.
* `<App>Web.Router` — the AshJsonApi router is additionally mounted on the generated
  `scope "/api"`, so `POST/GET/PATCH/DELETE /api/items` speak JSON:API.
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
* `.env.example` — `DATABASE_URL`, the emulator endpoints, `STORAGE_BACKEND`, and the
  broker block (`HEALTH_PORT` for the worker).
* `config/runtime.exs` — appended, *outside* the `if config_env() == :prod` block, so
  it applies in every environment: `:ex_aws` (with the `AWS_ENDPOINT_URL` host/port
  override and `ExAws.Request.Req` as the HTTP client, which keeps hackney out),
  `:storage`, and — for the worker — `:pipeline` and `:health_port`.

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
  >= 3.16 must be on `PATH` to compile it.

## Tests

```bash
mix test
```

The generators are exercised through `Igniter.Test.test_project/1` against the
`Tinderbox.Gen.*` modules directly — the Mix tasks are thin shells, and a test
project cannot fetch the packages declared in `installs:`.

Beyond that, generated projects were run end to end against the emulators:

* **worker / sqs** — `docker compose up -d --wait`, `mix ash.setup`, `mix run --no-halt`,
  a message sent to the inbound queue came out of the outbound queue with
  `processed_at` added; re-sending the same body produced **no** second message and
  left `inbox_messages` at one row (`mix ash.setup` output, `/health` 200).
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

Note for machines where 5432 is already taken: the generated `docker-compose.yml`
publishes Postgres on 5432; override the host port (and the dev `port:` in
`config/dev.exs`) if something else owns it.
