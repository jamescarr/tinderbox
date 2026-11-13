# Feedback: studio_next, the new generator features in one project

`studio_next` (local only, `~/projects/upmarkethq/studio_next`) is a second dogfood
project, generated after the nine `docs/plans/saas-next.md` bullets landed (socket-first
`report/3`, date seeding, `enum_options/2`, `bar_list`, the pricing grid, the activity
feed, API rate limiting, the `file` type and the `secret` type). The business is a stand-in:
a studio workspace with projects, documents attached to a project, and upstream services
whose API keys are secrets. Nothing was written by hand except `concept.exs` and
`.mise.local.toml`, plus the host-port edits in `docker-compose.yml` and
`docker/dex/config.yaml` described below. This bullet does not fix the generator; the
"Rough edges hit" section lists what each problem wants.

## Generation

```bash
cd ~/projects/upmarkethq
mix igniter.new studio_next --with phx.new \
  --install tinderbox@path:/Users/jamescarr/orca/workspaces/tinderbox/cutlassfish.plan-loop/b10 \
  --stack saas --yes
```

* **Duration**: 3 min 11 s (191 s wall time, measured around a `lockf` that waits for
  the shared check lock; Elixir 1.20.4-otp-29, Erlang 29.1, phoenix 1.8.15,
  ash_authentication 4.15.0, bandit 1.14.1, daisyUI 5.5.20).
* **Notices**: the usual ones. The "Next" notice still says `http://localhost:4000` and
  `mise run dev`; it now also lists `concept.exs` and `gen.concept` as the step after.
  The tinderbox path dependency was removed from `mix.exs` as designed.
* **Ports**: 5432, 1025, 8025, 4000 and 4002 are held by other projects here, and so are
  4566, 4588, 5556, 4444, 4445 (truebook's compose; its NATS is on 4226/8226). The
  generated `docker-compose.yml` hardcodes those host ports for Floci, floci-gcp, NATS
  (4222, 8222), Dex and Hydra, so the host side was edited by hand: Floci `4666`,
  floci-gcp `4688`, NATS `4310`/`8310`, Dex `5656`, Hydra `4410`/`4411`. Two strings
  that have to agree with a host port were edited too: Dex's `issuer` and redirect URIs in
  `docker/dex/config.yaml`, and Hydra's `URLS_SELF_ISSUER` in the compose file.
  `.mise.local.toml`:

  ```toml
  [env]
  PGPORT = "5610"
  SMTP_PORT = "2110"
  MAILPIT_UI_PORT = "8110"
  PORT = "4210"
  SSO_REDIRECT_URI = "http://localhost:4210/auth"
  ADMIN_EMAILS = "admin@tb.test"
  API_RATE_LIMIT = "3"
  AWS_ENDPOINT_URL = "http://localhost:4666"
  STORAGE_EMULATOR_HOST = "http://localhost:4688"
  NATS_PORT = "4310"
  SSO_BASE_URL = "http://localhost:5656/dex"
  OAUTH_ISSUER = "http://localhost:4410/"
  OAUTH_AUDIENCE = "http://localhost:4210/api"
  HYDRA_ADMIN_URL = "http://localhost:4411"
  ```

  The API connections page picked `OAUTH_ISSUER` and `OAUTH_AUDIENCE` up: its token
  endpoint read `http://localhost:4410/oauth2/token`.
* **`mise run check` on the untouched scaffold** was not run (the concept was applied
  first), so there is no scaffold test count to compare with `studio_demo`'s 63.

## The concept, applied

`concept.exs` was replaced with: name "Studio Next", tagline "Projects, documents and
upstream keys in one place", `cta: :waitlist`, three value propositions, the two
default plans (Starter, Pro), `domain: "Core"`, the resources

```elixir
%{name: "Project", attributes: "name:string:required status:enum:draft,active,archived budget:decimal starts_on:date:required", nav: "Projects", icon: "hero-folder"},
%{name: "Document", attributes: "title:string:required attachment:file:required project:belongs_to:Project:required", nav: "Documents", icon: "hero-document"},
%{name: "Upstream", attributes: "name:string:required api_key:secret:required", nav: "Upstreams", icon: "hero-key"}
```

`activation_event: "project.created"` and
`thresholds: %{within_days: 30, visitors: 2, waitlist: 1, registered: 1, activated: 1, paying: 1}`.

* `mise exec -- mix studio_next.gen.concept --yes` took 5 s: it updated
  `config/config.exs`, `lib/studio_next/concept.ex`, `layouts.ex`, `router.ex` and
  `test/support/fixtures.ex`, and created `StudioNext.Core`, three resources, nine
  LiveViews, three test files, `add_core` and six resource snapshots (a table and a
  `_versions` table per resource). Without `--yes` it stopped at a prompt (see "Rough
  edges").
* The `Project` migration, form and fixtures carry the new types: `starts_on` is a
  required `date`, `Document.attachment` is a `map` with the `key`/`filename`/
  `content_type`/`size` constraint, and `Upstream` has `encrypted_api_key bytea NOT NULL`
  and no `api_key` column.
* `mise run check`: first run failed at `mix format --check-formatted` on `concept.exs`
  itself (see "Rough edges"); after `mix format concept.exs`, **90 tests passed**, 142 s
  with the first compile of the dev and test builds (the compile step is
  `--warnings-as-errors` and was clean).
* The generated Floci-backed tests (document live test, file controller test) ran against
  the compose Floci on the remapped port without any change.

## In a browser (`mise run dev`, headless Chromium, the app on 4210)

* **Pricing grid** (`/`): the two plans render in
  `mt-8 grid gap-4 mx-auto max-w-3xl sm:grid-cols-2`, centred; the three value cards in
  `grid gap-4 sm:grid-cols-3`. The page has `max-w-3xl sm:grid-cols-2` and no
  `lg:grid-cols-3`. Tab title "Projects, documents and upstream keys in one place · Studio
  Next".
* **Registration and organization**: `/register` as `owner@tb.test`, redirected to `/`;
  `/dashboard` sent a user without an organization to `/organizations/new`; creating
  "Acme Studio" landed on `/dashboard`. The sidebar listed Dashboard, Inbox, Members,
  **Activity**, Billing, API connections, Projects, Documents, Upstreams.
* **Project** (`/projects/new`): the `starts_on` date input arrived prefilled with today
  (`2026-11-13`), and the status select offered `Draft`, `Active`, `Archived` (the form
  uses `enum_options`). Saving `Alpha`, Active, budget `1500` **failed the first time**
  (rough edge 1: a flash saying "Something went wrong" and nothing saved). With a local
  `Jason.Encoder` implementation for `Decimal` in the project (a workaround, since
  removed) the same form saved and `/projects/<id>` showed `Alpha`, `Active`, `1,500.00`,
  `2026-11-13`.
* **Document upload and download**: `/documents/new` showed a title, a file input and the
  project select (`Alpha`). Choosing `brief.txt` listed it as a pending upload; saving
  went to `/documents/<id>` with the attachment shown as a link
  `/files/<org id>/documents/<uuid>/brief.txt`. A `fetch` of that link answered 200,
  `content-type: application/octet-stream`,
  `content-disposition: attachment; filename="brief.txt"; filename*=UTF-8''brief.txt`,
  `x-content-type-options: nosniff` and the body `hello studio next`. Editing the
  document showed "Current file: brief.txt. Choose another to replace it." and saving a
  new title kept the same file. A `brief.pdf` upload was served
  `inline; filename="brief.pdf"` as `application/pdf`. A key of the user's own
  organization that does not exist, a nil UUID and a non-UUID first segment all answered
  404; `curl` without a session was redirected to `/sign-in`; a second user (`other@tb.test`,
  organization "Other Co") got **404** for the first organization's file, and
  `/projects` for them said "No projects yet".
* **Upstream and the secret**: the form's key input is `type="password"
  autocomplete="off"` and empty on edit. Saving `sk_live_TOPSECRET123` showed `Api key
  ••••••` on the show page and the list; the page HTML never contained the value, nor did
  the edit form. Postgres: `upstreams` has `encrypted_api_key bytea NOT NULL` (88 bytes)
  and no `api_key`; `upstreams_versions.changes` contains only `name` and
  `organization_id`, and the `upstream.create` event on NATS carries `id`, `name`,
  `organization_id` and nothing secret. After an edit that left the key blank the row
  still held a non-null `encrypted_api_key` (88 bytes), and an edit that only typed a new
  key saved.
* **`/activity`** (owner): newest first, "owner@tb.test created Organization Acme
  Studio", "created Membership 58fbaf3f" (Role owner), "created Project Alpha" (Budget
  1500, Name, Starts on, Status), "created Document Kickoff brief", "updated Document",
  "created/updated Upstream Payments API" (Name only, never the key), and after deleting
  the document (the page asks with a browser `confirm`) a new first entry "owner@tb.test
  deleted Document Kickoff brief v2". The second user's feed held only their own
  organization and membership entries.
* **`/dev/ui`**: the "Bar list" card renders three `<progress>` elements with
  `aria-label`s "Public equity: $62,500", "Real estate: $25,000", "Cash: $12,500" and
  values 62.5 / 25 / 12.5, shares printed as 62%, 25%, 13%.
* **API rate limit** (`API_RATE_LIMIT=3`, `.mise.local.toml`; Hydra client-credentials
  token for a new "CI runner" connection, `GET /api/organizations`): requests 1 to 3
  answered 200 with `x-ratelimit-limit: 3` and `x-ratelimit-remaining` 2, 1, 0; requests
  4 and 5 answered **429**, `retry-after: 60`, `x-ratelimit-remaining: 0` and
  `{"errors":[{"status":"429","title":"Too Many Requests","detail":"Rate limit exceeded;
  retry after 60 seconds"}]}`. A request without a token afterwards had its own bucket
  (`ip:127.0.0.1`: 200, remaining 2) and listed no organizations.
* `docker compose down -v` and `mise run down` at the end freed the ports; the stack was
  left removed, `studio_next` left in place.

## Rough edges hit

1. **A decimal attribute cannot be created in dev** (the one blocker). Creating a
   `Project` with `budget` failed inside the transaction on the `projects_versions` insert:
   `protocol Jason.Encoder not implemented for Decimal (a struct)`, because AshPaperTrail
   puts the `Decimal` into the version's `changes` map and Postgrex encodes it with Jason.
   The form only showed "Something went wrong" (`Unhandled error in form submission ...
   Ash.Error.Unknown.UnknownError does not implement AshPhoenix.FormData.Error`). The same
   project's `mise run check` passed (the fixture and the generated live test both use a
   decimal) and `MIX_ENV=prod`/`test` have Jason's `Decimal` implementation; only the dev
   build did not: `Jason.Encoder.impl_for(Decimal.new(1))` is `Jason.Encoder.Any` in
   dev and `Jason.Encoder.Decimal` in test and prod. `mix deps.compile jason --force`
   fixed dev at once. Jason's implementation is guarded by `Code.ensure_loaded?(Decimal)` at
   its compile time, so a dev build of Jason that happened before Decimal was on the code
   path during `igniter.new --install` keeps it forever. [INFERENCE: the ordering cause;
   the symptom and the fix are observed.]
   *Wants*: the installer's last step force-recompiles `jason` (or generates the project so
   `decimal` is compiled first). The test suite cannot catch it, because only the dev
   build is affected. A hand-written `defimpl Jason.Encoder, for: Decimal` in the project is *not* the
   fix: it compiled but printed `redefining module Jason.Encoder.Decimal` in the test and
   prod builds, and `MIX_ENV=prod mix compile --warnings-as-errors` failed on that one
   warning. The form should also render non-form Ash errors as a flash with the message
   instead of a bare "Something went wrong".
2. **The generated compose file hardcodes host ports.** `4566`, `4588`, `4222`/`8222`,
   `5556`, `4444`/`4445` (Postgres, SMTP and the Mailpit UI are already
   `${PGPORT:-5432}`-style). Any machine with another project on those ports has to edit
   `docker-compose.yml` and then also fix everything derived from them by hand: Dex's
   `issuer`/redirect URIs, Hydra's `URLS_SELF_ISSUER`, and `AWS_ENDPOINT_URL`,
   `STORAGE_EMULATOR_HOST`, `NATS_PORT`, `SSO_BASE_URL`, `OAUTH_ISSUER`, `OAUTH_AUDIENCE`,
   `HYDRA_ADMIN_URL` in `.mise.local.toml`. *Wants*: `"${FLOCI_PORT:-4566}:4566"` and so
   on for every published port, new variables in `Tinderbox.Env`, Dex's issuer and Hydra's
   `URLS_SELF_ISSUER` templated from the same variables (compose `environment:` can,
   `docker/dex/config.yaml` needs `DEX_ISSUER` or an `envsubst`-style entry), and the
   README's port table reading from them. This bullet does not fix the generator.
3. **`gen.concept` needs `--yes` outside a terminal.** The diff is over 1000 lines, so
   Igniter asks "How would you like to proceed?"; with no TTY it crashes with
   `FunctionClauseError ... String.trim/1 ... :eof`. The `concept.exs` header and the
   "Next" notice say `mise exec -- mix studio_next.gen.concept`. *Wants*: say `--yes` (or
   "answer 0 at the prompt") there.
4. **`mix format --check-formatted` rejects an edited `concept.exs`**: `.formatter.exs`
   includes it, the long strings and one-line maps the file invites are reformatted, and
   `mise run check` fails before any test. *Wants*: the header says "run `mix format
   concept.exs` after editing", or the formatter config excludes it.
5. **A required file input shows "is required" after a file is chosen.** On the new-document
   form, picking `brief.txt` listed it as a pending upload and the live validation still
   printed "is required" under Attachment until the form was saved (the save then worked).
   *Wants*: the form's validate step clears the file field's required error while
   `@uploads.<name>.entries` is not empty.
6. **Secrets reach the dev log.** Phoenix's default `filter_parameters` only knows
   `"password"`; every keystroke's `HANDLE EVENT "validate"` line and the `"save"` line
   print `"api_key" => "sk_live_TOPSECRET123"`. They are `[debug]` lines (LiveView events)
   but the generated project's dev log and any debug-level production log carry them.
   *Wants*: the `secret` generator adds the attribute name to
   `config :phoenix, :filter_parameters` (and the form's input name stays
   `upstream[api_key]`).
7. **The activity feed's rendering is rough in four places.**
   (a) A `file` value prints as an Elixir map,
   `%{"content_type" => "text/plain", "filename" => "brief.txt", "key" => "...", "size" => 18}`;
   (b) the label comes from the *current* source row, so a rename rewrites history
   ("created Document Kickoff brief v2" while the change shows `Kickoff brief`), and after a
   delete the same entry flips back to the old name; (c) a secret-only edit is a version
   with an empty `changes`: "updated Upstream Payments API v2" with nothing under it;
   (d) foreign keys read "Project id 4645daf6-..." and a membership is "Membership
   58fbaf3f" with "User id <uuid>". *Wants*: `Activity` formats a change by the attribute's
   type (file: the filename, `belongs_to`: the related record's name or hidden), takes the
   label from the version's own `changes` first, and leaves an empty-changes version out
   (or says "changed a secret").
8. **Deleting a document leaves its file in storage.** After the delete, the Floci bucket
   still listed `<org id>/documents/<uuid>/brief.txt`. Versions keep the key, so the feed
   still points at it, but the file controller authorizes by organization only. *Wants*: a
   decision, then either a destroy `after_action` that deletes the object or a README line
   that files outlive records (and a retention story).
9. **Generated tests write into the dev bucket.** The Floci bucket `studio-next-local`
   held `notes/.../hello.txt`, `notes/.../logo.png` and `documents/.../attachment.txt` from
   the generated file controller and document tests, next to the dev uploads, and nothing
   removes them. *Wants*: tests use their own bucket (or a per-run key prefix) and an
   `on_exit` cleanup.
10. **The rate-limit key behind a proxy** (not exercised, code read): anonymous callers
    are keyed by `conn.remote_ip`, and the app has no `RemoteIp`-style plug or
    `x-forwarded-for`/`fly-client-ip` handling, so on Fly every anonymous client would share
    the proxy's bucket. [INFERENCE: the behaviour on Fly; the missing plug is observed.]
    *Wants*: a trusted-proxy plug in the Fly files (or the plug reading `fly-client-ip`).
11. **A Postgres identifier is silently shortened.** Migrating `add_saas_resources`
    logged `identifier "subscriptions_versions_organization_id_version_inserted_at_index"
    will be truncated to "subscriptions_versions_organization_id_version_inserted_at_inde"`.
    Harmless here, but two long table names sharing a prefix can collide. *Wants*:
    `VersionIndexes` gives the index an explicit short `name:`.
12. **Dependency advisories on every `mix deps.get`**: `assent 0.2.13`
    (EEF-CVE-2026-117656, CRITICAL, Sign in with Apple callback parameters) is new since
    `studio_demo`, next to the known `cloak 1.1.4` (EEF-CVE-2026-95105, HIGH). Bump when
    fixed releases exist; nothing in the template changes it.
13. **`mise run dev` on a fresh database prints every migration's SQL** (several hundred
    lines of `[info]`) before "Running StudioNextWeb.Endpoint"; cosmetic.

Not exercised: Stripe and billing, SSO through Dex (its issuer and redirect URIs were
remapped but nobody signed in through it), the Fly.io deployment and the release image, a
Redis-backed Hammer backend or more than one node (the counter is per-node ETS), MFA and
`MFA_REQUIRED`, the validation funnel at `/admin/validation` and the waitlist form (both
unchanged since `studio_demo`), the invitation flow, and the `/dev/ui` modal's
server-opened example. (Deleting a document from the index page, which goes through the
socket-first `report/3`, removed the row and the list showed its empty state.)
