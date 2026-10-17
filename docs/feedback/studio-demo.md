# Feedback: studio_demo, concept to validated scaffold

`studio_demo` (local only, `~/projects/upmarkethq/studio_demo`) is the first project
generated with the venture-studio additions to the SaaS stack: `concept.exs` and
`mix studio_demo.gen.concept`, the project's own `gen.resource` / `gen.live`
generators, first-party analytics with the validation funnel, the waitlist, and the
Fly.io files. The business is a stand-in: teams tracking projects (name, status,
budget) and their tasks. Nothing was written by hand except `concept.exs` and
`.mise.local.toml`.

## Generation

```bash
cd ~/projects/upmarkethq
mix igniter.new studio_demo --with phx.new \
  --install tinderbox@path:/Users/jamescarr/orca/workspaces/tinderbox/agentic-cycle-factory \
  --stack saas --yes
```

* **Duration**: 3 min 40 s to 4 min 36 s over four runs (Elixir 1.20.4-otp-29, Erlang
  29.1; a fresh resolution picked ash 3.36.1, ash_authentication 4.15.0, phoenix
  1.8.15, phoenix_live_view 1.2.12).
* **Notices**: the usual ones, and the next step now ends with
  `then edit concept.exs and run mise exec -- mix studio_demo.gen.concept`.
* **Ports**: 5432, 1025, 8025, 4000 and 4002 are held by other projects on this
  machine; NATS, Dex, Hydra and Floci's ports were free. `.mise.local.toml`:

  ```toml
  [env]
  PGPORT = "5458"
  SMTP_PORT = "1028"
  MAILPIT_UI_PORT = "8028"
  PORT = "4113"
  SSO_REDIRECT_URI = "http://localhost:4113/auth"
  ADMIN_EMAILS = "admin@studio.test"
  ```

* **`mise run check` on the untouched scaffold**: 63 tests passed (the 13 of the
  last runs, the MFA suite, and the new analytics, waitlist, validation-page and
  number-formatting tests), 94 s with the first compile.
* **flyctl** installed through mise (`github:superfly/flyctl` 0.4.118).

## The concept, applied

`concept.exs` was replaced with the business: name "Studio Demo", tagline "Track
projects without the spreadsheet", `cta: :waitlist`, three value propositions, two
plans, `domain: "Core"`, the resources

```elixir
%{name: "Project", attributes: "name:string:required status:enum:draft,active,archived budget:decimal", nav: "Projects", icon: "hero-folder"},
%{name: "Task", attributes: "title:string:required done:boolean project:belongs_to:Project:required", nav: "Tasks", icon: "hero-check-circle"}
```

`activation_event: "project.created"` and
`thresholds: %{within_days: 30, visitors: 2, waitlist: 1, registered: 1, activated: 1, paying: 1}`.

* `mise exec -- mix studio_demo.gen.concept` took 7 s: it rewrote
  `lib/studio_demo/concept.ex`, created `StudioDemo.Core` (registered in
  `ash_domains`), both resources, six LiveViews, eight routes inside
  `:authenticated_routes`, two sidebar entries before the admin section, two fixtures,
  two test files and one `add_core` migration.
* `mise run check`: 71 tests passed (eight new: per resource, an owner adds one and
  lands on it, deletes one, a member reads but cannot add, another organization's
  record is not found). `MIX_ENV=prod mix compile --force --warnings-as-errors` was
  clean, and `mix studio_demo.gen.resource` in prod exits saying it needs igniter.
* Running `gen.concept` again changed nothing and said both resources were skipped;
  `gen.live` on an existing resource changed nothing and said so.
  `gen.resource StudioDemo.Core.Bad organization_id:uuid name:money` exited listing
  both problems and the grammar, before writing anything.
* A throwaway `gen.live StudioDemo.Core.Note` with one attribute of every type
  (`text integer date datetime uuid map boolean`, a required unique string, a required
  `belongs_to:User` and an optional `belongs_to:Project`) passed its four generated
  tests next to the rest (75), then was reset away.

## In a browser (`mise run dev`, headless Chromium)

* `/?utm_source=newsletter&utm_campaign=launch`: "Studio Demo", the tagline and the
  description, three cards, two pricing cards, the waitlist form carrying the
  campaign in hidden fields; tab "Track projects without the spreadsheet · Studio
  Demo". Joining with `lead@example.com` flashed "You're on the list. We'll write to
  lead@example.com."
* Registering `owner@example.com`, creating "Acme Studio": the sidebar listed
  Projects and Tasks. New project → `Alpha`, Active, budget `1500` → `/projects/<id>`
  showing `Alpha`, `Active`, `1,500.00`. `/tasks/new` offered `Alpha` in the project
  select; the task's page showed `Done Yes`, `Project Alpha`.
* An invitation from the members page, accepted by a newly registered
  `member@example.com`: `/projects` listed Alpha without "New project" or row
  actions, `/projects/new` went back to `/dashboard` with "Only owners and admins can
  open that page", and `/admin/waitlist.csv` answered 404.
* As `admin@studio.test` (`ADMIN_EMAILS`), `/admin/validation`: Visitors 1, Waitlist
  1, Registered 3, Organizations 1, Activated 1 (`project.created`), Paying 0, Active
  (7 d) 3; verdict "Day 1 of 30: 3 of 5 thresholds met — Short: Visitors 1 of 2,
  Paying 0 of 1"; the eight-week table. `/admin/waitlist` listed the lead with
  `newsletter` / `launch`; the CSV was one header and one data row,
  `text/csv`, `attachment; filename="waitlist.csv"`.

## The release image

* `docker build .` with the generated Dockerfile: 1 min 47 s.
* fly.toml's release command, run in the image
  (`/bin/sh -c 'DATABASE_URL=${DIRECT_DATABASE_URL:-$DATABASE_URL} exec /app/bin/migrate'`,
  no `DIRECT_DATABASE_URL`): "Migrations already up" against the compose Postgres.
* The release (`PHX_SERVER=true`, NATS on the host): "JetStream stream and consumer
  are ready", `/health` `{"status":"ok"}` 200, `/` 200 with the concept's title.

## Fixed in the generator from this run

* **ash 3.36 and the identity resource**: `mix ash.codegen` stopped on
  `Accounts.UserIdentity` ("Multiple actions (2) with the name `read`"): the
  AshAuthentication installer helper writes `actions do defaults [:read] end`, and
  the UserIdentity extension now adds its own primary read beside it. The generator
  removes that block (the extension builds the read action whichever version runs).
* **Elixir 1.20's type checker and the concept**: the landing page compared
  `StudioDemo.Concept.cta() == :waitlist` while `cta/0` returned `:register`, a
  comparison of disjoint types, which `--warnings-as-errors` refuses. The page now
  gets the concept as an `@concept` assign from `PageController`.
* **The root layout's formatting**: `default={StudioDemo.Concept.tagline()}
  suffix={" · " <> StudioDemo.Concept.name()}` made `<.live_title>` too long, and the
  HEEx formatter (which the generator does not run on `.heex`) wanted it broken up.
  The layouts carry `tab_default/0` and `tab_suffix/0`; the tag stays short for any
  app name.
* **Names**: a page without a title read "StudioDemo · Studio Demo" and the app shell
  said "StudioDemo"; they use the tagline and the concept's name now.
* **Scale and repeatability of the generated CRUD** (after review, re-verified on a
  fresh `studio_demo`: 63 → 71 tests, then a `Milestone` with a unique string, a
  unique integer and two `belongs_to` → 75, prod compile clean): resources index
  `[:organization_id, :inserted_at]` and every `belongs_to` column (the migration
  creates the three indexes); the list page and the form's selects read at most 1000
  rows; a unique attribute's fixture value is unique per call; and a test runs
  `gen.concept` twice to prove its own rewrite keeps the marker.

## Rough edges hit

* **Regenerating a project under the same name** keeps compose's Postgres volume:
  the second `mise run check` failed with `relation "analytics_events" already
  exists` until `docker compose down -v`. Not the generator's to fix.
* **One browser is one visitor**: everyone who used the same browser shares the
  visitor cookie, so "Visitor → registered" read 300%. The rates are not capped, and
  the README says a rate can pass 100% when people skip a step.
* **Two plans in a three-column pricing grid** leave a gap on wide screens.
* **`paying` needs Stripe**: with no subscription the paying threshold stays unmet,
  as it should; the Stripe flow itself was not exercised here.
* **`cloak 1.1.4 VULNERABLE!`**: `mix deps.get` reports EEF-CVE-2026-95105 (HIGH,
  "Cloak AES-CTR cipher lacks ciphertext authentication"). The generated vault uses
  `Cloak.Ciphers.AES.GCM`, which authenticates, not AES-CTR; still, every SaaS project
  ships the package, so bump `cloak` (or `ash_cloak`'s requirement) once a fixed
  release exists. Not addressed here.

Not exercised: the Fly.io deployment (the run was kept local by choice: apps, a
Managed Postgres cluster and a Tigris bucket are billable), so Managed Postgres
behind PgBouncer, `DIRECT_DATABASE_URL`, NATS on a Fly volume over 6PN, Tigris and
Resend are untested; SSO (Dex) on the moved port; Stripe; more than one node.
