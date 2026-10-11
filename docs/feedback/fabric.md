# Feedback: building fabric on the SaaS stack

fabric (`jamescarr/fabric`, private) is a SaaS project generated with this package and
extended into an MCP integration fabric. Organizations register upstream MCP servers
with brokered credentials and create agents with hashed API keys and per-agent policy.
MCP clients point at one gateway endpoint (`POST /mcp`), which aggregates tools,
enforces policy and rate limits, versions upstream tool schemas, records every call
and dead-letters failed calls for replay. The scaffold is `main`; the work is draft PR
`jamescarr/fabric#1`.

This file lists what the generated stack was missing or got wrong for that work. Each
entry names the fabric file that does the job by hand.

## Generation

```bash
cd /Users/jamescarr/projects/upmarkethq
mix igniter.new fabric --with phx.new \
  --install tinderbox@path:/Users/jamescarr/orca/workspaces/tinderbox/the-run \
  --stack saas --yes
```

* **Duration**: 3 min 35 s wall clock (Elixir 1.20.4-otp-29, Erlang 29.1, deps
  fetched from Hex, nothing cached for this project).
* **Git**: `mix igniter.new` ran `git init` and committed everything itself
  (`🔥 initial commit 🔥`, 139 files). No `git init` was needed. That commit is
  `main` of `jamescarr/fabric`.
* **Warnings printed** came only from dependencies:
  * Elixir 1.20 type warnings in `gettext`, `dns_cluster`, `ash`,
    `ash_json_api`, `ash_phoenix`, `sweet_xml` and `opentelemetry_phoenix`;
  * ex_aws's `xref: [exclude: …]` deprecation, four times;
  * `Postgrex.Interval.to_string/1 is undefined` from `phoenix_live_dashboard`.

  fabric's own 76 files compiled without a warning.
* **`Warning: this migration includes destructive operations`** is printed for the
  initial migration, where there is nothing to drop. AshPostgres prints it for every
  `ash.codegen`, because the generated `down/0` drops what `up/0` creates. fabric's
  three add-only migrations printed it too. The generator cannot silence it, but the
  README could say it is expected, so nobody opens the initial migration looking for
  a drop.
* **Notices**: `min_pg_version/0`, the picosat notice, the Stripe set-up
  notice and the `mise trust && mise run dev` next step. All accurate.
* **Ports**: `mise run check` failed on `up` straight away with
  `Bind for 127.0.0.1:1025 failed: port is already allocated`. Other compose
  projects on the machine held 5432, 1025, 8025 and 4000.
  * The README's fix is a `docker-compose.override.yml`. It works, but
    `.gitignore` does not list the file, so it had to be kept out of git by hand
    (`.git/info/exclude`).
  * `SMTP_PORT` and `PORT` are read in `runtime.exs`, so `.mise.local.toml` covers
    Mailpit and Phoenix.
  * Postgres is different (next entry). fabric now reads
    `port: String.to_integer(System.get_env("PGPORT", "5432"))` in
    `config/dev.exs` and `config/test.exs`.

  Candidates:
  * generate that `port:` line;
  * publish compose ports as `${POSTGRES_PORT:-5432}:5432`, and the same for
    Mailpit, so `.mise.local.toml` is the only file to touch;
  * add `docker-compose.override.yml` to the generated `.gitignore`.
* **`PGPORT` splits `mix ash.setup` across two servers, and the failure looks like
  a pool timeout.** Setup: `PGPORT=5455` in `.mise.local.toml`, no `port:` in the
  repo config. The first `mise run check` then failed in `mix test`'s
  `ash.setup --quiet` with `database "fabric_test" does not exist`, then
  `connection not available and request was dropped from queue after 5998ms`.
  * The create step (`storage_up`) goes through Postgrex's defaults, honours
    `PGPORT`, and created `fabric_test` on 5455.
  * The migrate step starts the repo pool.
    `Ecto.Adapters.Postgres.Connection.child_spec/1` does
    `Keyword.put_new(:port, 5432)`, so the pool went to another project's Postgres
    on 5432.
  * `mix ash.setup` therefore reports "has already been created" and then fails to
    migrate that same database.

  Running `MIX_ENV=test mix ash.setup` by hand, from a shell without mise's
  environment, "fixed" it: it created `fabric_test` on the other project's server,
  and later runs passed there. Nobody noticed until a dev `mix ash.setup` printed
  "has been created" for a database compose had already created. The stray
  databases were dropped. The README should say two things: run `mix` through mise
  (`mise exec -- mix …`) whenever `.mise.local.toml` matters, and set the port in
  the repo config, never through `PGPORT` alone.
* **`mise run check` on the untouched scaffold**: on this machine the scaffold's
  repo config points at 5432, which belongs to another project, so the untouched
  scaffold never ran against its own Postgres. Its five Phoenix tests did pass
  against the other server, by the accident above. With the `port:` line, `check`
  passes against fabric's Postgres on 5455.

## Hand-written in fabric that the SaaS stack should generate or offer

* **Encrypted attributes.** Added `cloak` + `ash_cloak`, `Fabric.Vault`
  (`lib/fabric/vault.ex`) as a supervised child, and `CLOAK_KEY` in `runtime.exs`,
  `.mise.toml` and `.env.example`. `runtime.exs` uses a dev default and raises in
  prod when the key is unset. `Fabric.Upstreams.Upstream` encrypts `auth_secret`
  with `decrypt_by_default []` and `encrypt_nil? false`. Any SaaS app that stores
  third-party credentials needs this. A `--with-vault` option could write all of it
  and pin AES-GCM (see the cloak advisory below).
* **A rate limiter.** `hammer` with the ETS backend: `Fabric.Gateway.RateLimit` as a
  child, used per agent in `Fabric.Gateway`. The counters are per node. A multi-node
  deployment needs Hammer's Redis backend, which is not wired.
* **A machine-principal credential**, distinct from AshAuthentication's user tokens:
  * a `fab_…` key (`Fabric.Agents.Key`) stored only as SHA-256, with a 12-character
    prefix for display;
  * the plaintext returned once, in the create/rotate result's metadata
    (`Fabric.Agents.Changes.GenerateKey`, `agent.__metadata__.plaintext_key`);
  * a `:by_key_hash` read, used by `Fabric.Gateway.Auth`;
  * a rotate action and a show-once banner (`FabricWeb.AgentsLive`).

  API keys for organizations or service accounts are a common SaaS need.
* **`Fabric.Accounts.managers/1`**: the owners and admins of an organization, as
  notification recipients (`lib/fabric/accounts.ex`). `SyncSubscription` keeps a
  private copy of the same query. Two fabric notifications (`schema.changed`,
  `dead_letter.created`) use it.
* **`FabricWeb.LiveHelpers`**: `find/4`, `report/3`, `error_message/1` and
  `manager?/1`, plus `status_badge/1`, `format_time/1` and `pretty/1`. Every
  generated LiveView carries private copies of the first four
  (`MembersLive` was left alone).
* **An organization-scoped CRUD LiveView template.** All six fabric pages
  (`upstreams_live.ex`, `upstream_live.ex`, `agents_live.ex`, `agent_live.ex`,
  `calls_live.ex`, `dead_letters_live.ex`) repeat the same shape:
  * the three `on_mount` hooks;
  * `<Layouts.app>` with its five assigns;
  * a list filtered on `organization_id`;
  * an `AshPhoenix.Form.for_create` with a hidden `organization_id`;
  * per-row actions through `find` + `Ash.update/destroy` + `report`;
  * `manager?` gating.

  A `mix tinderbox.gen.live <Resource>` (or a page template in the docs) would save
  most of that.
* **The organization policy convention, written down.**
  `ActorManagesOrganization` reads `organization_id` off the changeset, so every
  writable resource needs that attribute. Resources whose organization comes from a
  parent must copy it with a plain change, not a hook, so the policy sees it
  (`Fabric.Agents.Changes.InheritOrganization` on `Grant`). The stack uses the
  convention without documenting it.
* **Oban queues and `ash_domains` by hand.** Each new domain went into
  `config :fabric, ash_domains:` and each new queue (`upstreams`, `dead_letters`)
  into the Oban config, both in `config/config.exs`. A
  `mix tinderbox.gen.domain` that registers both would remove the step that is
  easiest to forget: AshOban only sees triggers of registered domains.
* **A PromEx plugin scaffold.** `Fabric.PromEx.Plugins.Gateway`
  (`lib/fabric/prom_ex/plugins/gateway.ex`) turns
  `[:fabric, :gateway, :call, :stop]` and `[:fabric, :gateway, :rate_limited]` into
  `fabric_gateway_calls_total{status,upstream}`,
  `fabric_gateway_call_duration_milliseconds` and
  `fabric_gateway_rate_limited_total`. The stack could ship an empty
  `<App>.PromEx.Plugins.App` plugin, already in `plugins/0`, with the event naming
  convention in its moduledoc.
* **Test fixtures** (`test/support/fixtures.ex`): `user_fixture`,
  `organization_fixture`, `membership_fixture`, plus fabric's own. None are
  generated, and the generated tests cover none of the SaaS features. Also a
  LiveView sign-in helper (`test/support/live_helpers.ex`):
  `conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)`.
  It works with a user from `register_with_password`, whose metadata carries the
  token. Generating both would make the first SaaS test a five-line file.
* **An MCP client over Req and a demo MCP server under `/dev`**:
  * `Fabric.Mcp.Client`: Streamable HTTP, JSON and event-stream responses, a
    session cache, re-initialize on 404;
  * `Fabric.Upstreams.TokenBroker`: OAuth client credentials;
  * `Fabric.Mcp.DemoServer`: forwarded at `/dev/demo`, and the test double through
    Req's `plug:` option.

  With `Fabric.Gateway`, this is the core of an "MCP gateway" option for the stack.
* **A manager-only LiveView guard.** fabric computes `manager?` per page and hides
  the forms. Every action also goes through the policies, so this is UX, not
  security. An `on_mount {<App>Web.LiveOrganization, :require_manager}` would
  suit pages that are manager-only throughout.
* **A README for the generated project.** The generated `README.md` is Phoenix's
  stock one and says nothing about the stack: mise tasks, compose services, the SaaS
  features, the environment. fabric's README was rewritten. The generator could
  write the stack's section of the tinderbox README into the project.

## Rough edges hit

* **The generated CI workflow fails on the first push.** `.github/workflows/ci.yml`
  runs `jdx/mise-action` and then `mise run check`. On `main` (the untouched
  scaffold) and on the PR it stopped at `mix format --check-formatted`:
  `Mix requires the Hex package manager to fetch dependencies`, then
  `Could not find an SCM for dependency :sweet_xml`. There are three causes:
  * mise's Elixir comes without Hex;
  * `mise run check` never runs `mix deps.get`, so a fresh clone has to run
    `mise run setup` first;
  * the scaffold's `mix.exs` keeps the installer as
    `{:tinderbox, path: "/Users/jamescarr/orca/workspaces/tinderbox/the-run", only: [:dev, :test]}`,
    a path that exists only on the machine that generated it.

  fabric's fix (`3d4e470`) adds `mix local.hex --force && mix local.rebar --force`
  and `mix deps.get` steps and removes the `tinderbox` dependency. With it, the
  workflow passed on the PR in about eight minutes: the compose services on
  `ubuntu-latest`, the full `check`, 53 tests. Candidates for the stack: generate
  those two steps (or make `check` depend on a `deps` task), and drop the installer
  dependency after install or write it as a Hex/GitHub dependency.
* **`mix deps.get` reports `cloak 1.1.4 VULNERABLE! EEF-CVE-2026-95105 (HIGH)`**
  (AES-CTR has no ciphertext authentication) on every run. No fixed release
  exists. fabric uses `Cloak.Ciphers.AES.GCM`, which the advisory does not cover,
  and `Fabric.Vault`'s moduledoc says why CTR must not be used. A generated vault
  should pin GCM and carry the same note; otherwise people learn to ignore the
  advisory line. Cloak also prints two Elixir 1.20 warnings when it compiles
  (`iv_length` used in `size/1` without the pin).
* **AshCloak and validations.** AshCloak replaces the attribute with an argument
  and prepends a change that encrypts it in a `before_action` hook. Rules such as
  "a bearer upstream needs a secret" therefore have to run as a later
  `before_action` and read `encrypted_auth_secret`, falling back to the stored
  record on updates (`Fabric.Upstreams.Changes.ValidateAuthFields`). That only
  works with `encrypt_nil? false`; otherwise a blank secret is encrypted into a
  non-null value. Secrets also need their own update action (`:set_secret`):
  AshCloak encrypts whatever arrives, so an edit form without a secret field would
  wipe the secret on any action that accepts it.
* **The event notifier publishes every public attribute.** `Fabric.Events.AshNotifier`
  sends `public_attributes` as the payload, so `public?` doubles as "goes onto the
  event bus". `SchemaVersion.tools` (whole tool lists) and `DeadLetter.arguments`
  are private to keep events small, and AshCloak makes encrypted attributes
  private. The notifier's moduledoc says what is published, but a resource author
  thinks of `public?` as an API flag.
* **`AshOban.schedule_and_run_triggers/1` does not run jobs by default** in
  ash_oban 0.9: `drain_queues?` defaults to `false`. Tests need
  `schedule_and_run_triggers({DeadLetter, :replay}, drain_queues?: true)`
  (`test/fabric/calls/dead_letter_test.exs`). `config :fabric, Oban,
  testing: :manual` was already in `test.exs`.
* **`Req` is `~> 0.5` in `mix.exs` but resolves to 0.7.5.** Not a problem, but
  the Req docs to read are 0.7's (`decode_body: false`, `Req.Response.get_header/2`).
* **The generated layout is too narrow for tables.** `Layouts.app` fixes
  `max-w-4xl`, and seven-column tables pushed their action buttons off-screen.
  fabric widened it to `max-w-6xl`. An attribute (`<Layouts.app wide>`) would let
  data pages opt in.

## Verified / not verified

* `mise run check` in fabric passes: formatting, warnings-as-errors compile, and
  53 tests. The tests cover:
  * the client against the demo server;
  * schema diff and sync;
  * agents and grants;
  * invocation, and dead-letter replay through AshOban;
  * the gateway's auth, policy, rate-limit and protocol errors;
  * the upstream and agent LiveViews.
* Smoke test against `iex -S mix phx.server` on port 4111, in a browser and with
  curl:
  * password registration and creating an organization;
  * three upstreams on the demo server (none, bearer, OAuth client credentials),
    each synced to `v1 (6 tools)`;
  * a replaced wrong secret giving `Sync failed: {:http, 401}`;
  * an agent with a show-once key, and a grant;
  * through the gateway: `initialize`, the notification's `202`, `tools/list`, a
    successful call, a tool error, and a dead-lettered call after two attempts
    (inbox notification included);
  * the rate limit's `-32000` on the fourth call in a minute, `401` without a key,
    `405` on `GET`;
  * a dead letter replayed after the demo tool recovered, with a second call row;
  * a breaking v2 schema: the flash, the version diff and badge, the inbox entry,
    and the tool list changing;
  * a grant pinned to v1 keeping the v1 tools;
  * `fabric_gateway_calls_total` on `/metrics`;
  * `upstream.create`, `schema_version.create` and `dead_letter.record` acked by
    `Fabric.Events.Handler` over NATS.
* The MCP Inspector CLI 2.10.1 (`--transport http`) listed the tools and called
  one through the gateway.
* GitHub Actions: the generated workflow failed on `main`. With fabric's fix, it
  passed on PR #1.
* Not exercised:
  * a real third-party MCP server or OAuth provider;
  * more than one node (the rate limit and the session and token caches are per
    node);
  * a release with `CLOAK_KEY`.
