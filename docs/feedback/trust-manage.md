# Feedback: building trust_manage on the SaaS stack

trust_manage (`jamescarr/trust-manage`, private) is a SaaS project generated with this
package and extended into a trust manager for a family trust. An organization is a
trust: owners and admins are trustees, members are view-only. It holds financial
accounts and their ledger, transfers that one trustee proposes and a *different*
trustee approves, bills with due-date reminders, other assets, and uploaded
documents, with an activity feed over all of it. Balances and transactions are
entered by hand; there is no bank sync. The scaffold is `main`; the work is draft PR
`jamescarr/trust-manage#1`, to be deployed to Fly.io (Google sign-in plus password,
Resend SMTP).

This file lists what the generated stack was missing or got wrong for that work. Each
entry names the trust_manage file that does the job by hand.

## Generation

```bash
cd /Users/jamescarr/projects/upmarkethq
mix igniter.new trust_manage --with phx.new \
  --install tinderbox@path:/Users/jamescarr/orca/workspaces/tinderbox/trust-manage \
  --stack saas --yes
```

* **Duration**: 3 min 40 s wall clock (Elixir 1.20.4-otp-29, Erlang 29.1, deps fetched
  from Hex, nothing cached for this project).
* **Git**: `mix igniter.new` ran `git init` and committed everything itself
  (`🔥 initial commit 🔥`, 145 files). That commit is `main` of
  `jamescarr/trust-manage`.
* **Warnings printed** came only from dependencies: Elixir 1.20 type warnings in
  `ash`, `ash_phoenix`, `ash_json_api`, `ash_authentication`, `gettext`,
  `dns_cluster`, `sweet_xml`, `prom_ex`, `phoenix_view` and `poly1305`;
  `Kernel.ParallelCompiler.async/1` deprecated; single-quoted charlists and
  `catch ...` in `yamerl`; ex_aws's `xref: [exclude: …]` deprecation, repeated;
  `Postgrex.Interval.to_string/1 is undefined` from `phoenix_live_dashboard`;
  `unused require OpenTelemetry.Tracer` in `opentelemetry_phoenix`. trust_manage's
  own files compiled without a warning (`mix compile --warnings-as-errors` passes).
* **`Warning: this migration includes destructive operations`** is printed by
  `ash.codegen` for the initial migration and again for `add_finances`, whose
  `down/0` drops what `up/0` creates. As in fabric, expected and unavoidable.
* **Notices**: `min_pg_version/0`, the picosat notice, the Stripe set-up notice, the
  `mise trust && mise run dev` next step, and a new one: the `tinderbox` dependency
  was removed from `mix.exs` again after install, with the line to add back to
  re-run a generator. That fixes the path dependency that broke CI in fabric.
* **Ports**: 5432, 1025, 8025 and 4000 (and the test endpoint's 4002) are held by
  other compose projects on this machine. NATS 4222, Dex 5556 and Floci 4566/4588
  were free, so no `docker-compose.override.yml` was needed. Overrides used, in
  `.mise.local.toml`:

  ```toml
  [env]
  PGPORT = "5458"
  SMTP_PORT = "1028"
  MAILPIT_UI_PORT = "8028"
  PORT = "4113"
  SSO_REDIRECT_URI = "http://localhost:4113/auth"
  ```

  Moving the app off 4000 also needs
  `http://localhost:4113/auth/user/sso/callback` in `redirectURIs` of
  `docker/dex/config.yaml` (committed). This time compose publishes
  `${PGPORT:-5432}`, `${SMTP_PORT}` and `${MAILPIT_UI_PORT}`, `config/dev.exs` and
  `config/test.exs` read `PGPORT`, and `.gitignore` lists `.mise.local.toml` and
  `docker-compose.override.yml`: everything fabric had to patch by hand is
  generated, and `.mise.local.toml` was the only file to touch.
* **`mise trust && mise install && mise run check` on the untouched scaffold**: 7
  tests passed, 1 min 35 s including the first compile. Later runs of `check` take
  about 8 s.
* **CI on `main`** (the untouched scaffold): the generated workflow passed, 12 min
  47 s.

## Hand-written in trust_manage that the SaaS stack should generate or offer

* **Organization-scoped resource boilerplate.** All seven finance resources
  (`lib/trust_manage/finances/{account,transaction,transfer,bill,asset,document,activity_event}.ex`)
  repeat the same 15 lines: `belongs_to :organization` with `allow_nil? false`,
  `reference :organization, on_delete: :delete`, the read policy
  `exists(organization.memberships, user_id == ^actor(:id))`, a write policy through
  `ActorManagesOrganization`, and the timestamps. The README states the convention;
  a `mix trust_manage.gen.resource TrustManage.Finances.Account name:string …
  --org-scoped` next to `gen.domain` would write it. A resource that must hide data
  from platform admins has to *leave out* the
  `bypass actor_attribute_equals(:role, :admin)` that the six generated resources
  carry (`Organization`, `Membership`, `Invitation`, `Billing.Subscription`,
  `Notifications.Notification` and `Notifications.Preference`); a flag
  (`--no-admin-bypass`) would say so.
* **`InheritOrganization` and `SameOrganization`**
  (`lib/trust_manage/accounts/changes/inherit_organization.ex`,
  `lib/trust_manage/accounts/validations/same_organization.ex`). The README says a
  child resource copies `organization_id` with a plain change; each project writes
  that change. Its sibling, a validation that every referenced id belongs to the same
  organization, is needed as soon as a child points at two parents (a transfer's
  second account, a payment's account, a document's links). Both belong in the stack.
  One behaviour worth documenting: validations run before policies, so a forged id
  from another organization gets `belongs to another organization` (an `Invalid`
  error) where one that is consistent but foreign gets `Forbidden`
  (`test/trust_manage/finances/transfer_test.exs`). Generated since
  jamescarr/tinderbox#3; trust_manage uses the generated module.
* **An activity feed**: `lib/trust_manage/finances/activity_event.ex`,
  `activity.ex`, `changes/record_activity.ex`, `lib/trust_manage_web/live/activity_live.ex`.
  The stack ships AshPaperTrail on the accounts resources but nothing that reads
  back as "james@example.com completed transfer of $10,000.00 … — completed_on: — →
  2026-10-11", and nothing org-scoped to page through. `RecordActivity` writes the row
  in an `after_action` (so it exists exactly when the change committed) and diffs the
  action's `accept` list. Any SaaS app with an audit trail needs this.
* **Notifying managers from an action**: `lib/trust_manage/accounts/changes/notify_managers.ex`
  plus `Activity.notification/2` and five keys in `TrustManage.Notifications.Catalog`.
  `Accounts.managers/1` exists, but the `after_action` that calls `trigger/2` with it
  was written by hand for every call site; a `change {Notify, key: …, to: :managers}`
  would remove it. The catalog and the call site must also be kept in step by hand.
  The hand-written change started as an `after_action`: a raising adapter (the local
  one raises on `Ash.create!` and `Oban.insert!`) rolled back the transfer, and
  PubSub fired before the commit. Generated since jamescarr/tinderbox#3 as
  `change {NotifyManagers, key: …, data: {Module, :function}}`, which runs in an
  `after_transaction` and only logs a failure; trust_manage uses the generated module.
* **An organization-scoped CRUD LiveView template.** Ten pages
  (`lib/trust_manage_web/live/{accounts,account,transfers,transfer,bills,bill,assets,asset,documents,activity}_live.ex`)
  and the rewritten dashboard repeat one shape: the three `on_mount`
  hooks, `<Layouts.app … wide>`, a list filtered on `organization_id`, an
  `AshPhoenix.Form` with a hidden `organization_id`, per-row actions through
  `find/4` and `report/3`, a "Show archived" toggle, and `manager?` gating. Same
  gap as in fabric's feedback; `mix trust_manage.gen.live` would have written most of
  it. The four detail pages also each repeat a not-found redirect (`find/4` fails:
  flash, then `push_navigate` to the list).
* **File upload and authorized download**:
  `lib/trust_manage_web/live/document_upload_component.ex`,
  `lib/trust_manage_web/controllers/document_controller.ex`,
  `lib/trust_manage/finances/documents.ex` (an org-prefixed storage key). `TrustManage.Storage`
  (`lib/trust_manage/storage.ex`) had only `put/2` and `get/1`:
  * no `delete/1`, so an object was orphaned when the `:upload` action failed after the
    `put` (a document is archived, never destroyed, for the same reason);
  * no `presign/2`, so every download proxies the whole object through the app and
    holds it in memory (`Storage.get/1` returns a binary).

  The stack should ship `Storage.delete/1` and `Storage.presign/2`, and an upload
  component with the server-side-values-win rule (the browser must not choose the
  key, size or organization) and the content-type rule (only PDF and common images
  inline, `nosniff`, everything else `application/octet-stream`). Storage delete and
  presign are generated since jamescarr/tinderbox#3; trust_manage uses the generated
  module, and the upload component deletes the object when the row is refused.
  Downloads stay proxied through `DocumentController`, with no presign: inline versus
  attachment and `nosniff` are decided per request there.
* **Money**: `lib/trust_manage/money.ex` (`format/1`, `sum/1`) and
  `lib/trust_manage_web/components/finance_components.ex` (`<.money>`, status badges,
  `humanize/1`, `enum_options/2` for selects over a `one_of` constraint). The stack has
  no money formatting at all.
* **The Fly.io deployment**: `fly.toml`, `fly/nats/fly.toml`, and the deploy commands
  in the README. The generated Dockerfile and `bin/migrate` worked unchanged, but
  nothing describes how to run the app, NATS, Postgres and storage on Fly. Candidates:
  generate both files behind `--deploy fly`.
* **SMTP authentication and TLS**: `config/runtime.exs`, the mail block. The generated
  block hard-coded `tls: :never, auth: :never` (right for Mailpit, wrong for every
  real relay). trust_manage reads `SMTP_USERNAME` and `SMTP_PASSWORD` and, when the
  username is set, uses `auth: :always, tls: :always` with `verify_peer`,
  `:public_key.cacerts_get()`, SNI and a hostname check. Evaluating the block with
  `SMTP_USERNAME` set shows the options in place; no connection to Resend was made.
  Generated since jamescarr/tinderbox#3; trust_manage uses the generated module.
* **NATS over IPv6**: the `:nats` block of `config/runtime.exs` passed no `tcp_opts`.
  Fly's private network is IPv6-only, so trust_manage adds
  `tcp_opts: [:inet6, :binary]` when `NATS_INET6=true`. Generated since
  jamescarr/tinderbox#3; trust_manage uses the generated module.
* **Oban and PgBouncer**: `config/runtime.exs`, inside `if config_env() == :prod`.
  Fly Managed Postgres sits behind PgBouncer, which breaks LISTEN/NOTIFY (Oban's
  default notifier) and named prepared statements, so trust_manage sets
  `Oban.Notifiers.PG` and `prepare: :unnamed`. Generated since jamescarr/tinderbox#3
  behind `DATABASE_POOLER=pgbouncer`, which `fly.toml` sets; trust_manage uses the
  generated block.
* **A health-check header for `force_ssl`**: the `[[http_service.checks]]` block of
  `fly.toml`. `config/prod.exs` redirects plain HTTP unless the host is `localhost`
  (its `paths: ["/health"]` exclusion is commented out). A request to
  `/health` with `Host: trust-manage.fly.dev` and no `X-Forwarded-Proto` got `301`; with
  `X-Forwarded-Proto: https` it got `200 {"status":"ok"}` (production image, run
  locally). Fly's check reaches the machine the first way, so `fly.toml` sent the
  header. Generated since jamescarr/tinderbox#3: `/health` is exempt in
  `config/prod.exs` (`paths: ["/health"]`) instead of through the header, which
  trust_manage no longer sends.

## Rough edges hit

* **`AshOban.schedule_and_run_triggers/2` with `drain_queues?: true` raises outside
  the test environment**: `Cannot use the drain_queues? true option outside of the
  test environment, unless you are also using oban pro`. The plan's smoke test
  ("run `schedule_and_run_triggers(…, drain_queues?: true)` in `iex -S mix`") cannot
  work. In dev the call without `drain_queues?` schedules the trigger and the running
  queues do the rest: both trustees got `Sunrise Senior Living due …` by email. The
  README convention that mentions `drain_queues?` now says so; the generated README
  says so since jamescarr/tinderbox#3.
* **`<.button>` has no `type` attribute** (`rest` is `:global` plus `href navigate
  patch method download name value disabled`), and a `<button>` inside a form submits
  it. The Archive and Restore buttons therefore sit outside the `<.form>` they
  belong beside (`lib/trust_manage_web/live/account_live.ex`, `bill_live.ex`,
  `asset_live.ex`). Fixed in the generator since jamescarr/tinderbox#3 (it adds `type`
  to the list); trust_manage's own `core_components.ex` still has the stock list.
* **A hidden input named `id` is a compile warning** (HEEx: it overrides the form's
  id), which `mix compile --warnings-as-errors` turns into a failure. The void form's
  field is `entry_id`.
* **The generated nav does not hold nine links.** With Accounts, Transfers, Bills,
  Assets, Documents and Activity added, the `menu-horizontal` wraps under the brand.
  Also visible in the browser: tab titles end in ` · Phoenix Framework`, and
  `card bg-base-100 shadow` is indistinguishable from the page in the dark theme, so
  the generated dashboard's cards have no edge.
* **The runtime image prints `[UNIX-ESSIO] Failed open sctp dynamic library:
  libsctp.so.1`** on every start. Harmless (the app serves). The Dockerfile's
  `apt-get install` list has no `libsctp1`.
* **Validations run before authorization.** An outsider proposing a transfer from one
  of this trust's accounts into one of their own gets `belongs to another organization`
  instead of `Forbidden`, which tells them the id exists. The reconcile change
  (`lib/trust_manage/finances/changes/reconcile.ex`) therefore reads the account's
  balance as the actor, not with `authorize?: false`: a forged account id finds
  nothing, where a balance read before the policy would leak another trust's balance
  through "already matches the current balance".
* **The identity stops a double complete only.** Two trustees completing one approved
  transfer at once both pass the status validation, because `require_atomic? false`
  updates validate against the row they read. A unique index on
  `transactions (transfer_id, account_id)` (an Ash `identity`) makes the second post
  fail and roll back (`transfer_test.exs`, "completing the same approved transfer
  twice posts to the ledger once"). Cancel against complete and approve against
  reject post nothing, so no index sees them; each transition carries
  `change filter(expr(status == …))` instead (`transfer.ex`). AshPostgres puts the
  filter in the UPDATE's `WHERE`, the loser matches no row and gets `StaleRecord`,
  and it fails before `PostTransfer` posts anything (`transfer_test.exs`, "cancelling
  a transfer that was completed meanwhile …", "a second trustee's reject …"). The
  validations stay: they give a friendly message on a stale page. Ash's
  `get_and_lock_for_update` change would not have helped: by its source it re-reads
  the row in a `before_action`, after the validations.

## Verified / not verified

* `mise run check` passes: formatting, warnings-as-errors compile, 47 tests:
  * the 7 generated ones;
  * 22 on the finance domain: the two-person rule (the proposer's `:approve` is
    forbidden; a view-only member cannot propose; completing before approval is
    refused), the ledger (reconcile, void, a transfer's postings cannot be voided),
    bill payments (a monthly bill due 2026-01-31 moves to 2026-02-28; a one-time
    bill is archived), the hourly reminder (each trustee gets one notification, a
    second run sends none), notifications to the co-trustee, isolation between two
    trusts, and the transition races (cancelling a transfer completed meanwhile, and
    rejecting one a co-trustee approved meanwhile, are refused; a raising
    notification adapter is logged and never undoes the action);
  * 18 on the web side: the document download (200 inline for a member, 404 for
    another trust, redirect when signed out, attachment for a type the browser could
    run, 404 for a missing object, against Floci), the transfer pages (the proposer
    waits, the co-trustee approves, a view-only member sees no controls, a lone
    trustee is warned), the account page including a file upload through the
    LiveView upload component (and a refused row leaving no object behind), and every
    finance page rendering for a trustee and a view-only member.
* Smoke test with `mise run dev` on port 4113 and a headless Chromium:
  * password registration, creating the trust, inviting a co-trustee as admin (the
    invitation email arrived in Mailpit), the co-trustee registering and accepting;
  * Savings ($50,000) and Brokerage ($0); a $10,000 transfer proposed by one trustee
    ("Waiting for another trustee to approve", no Approve button), the other's inbox
    and email showing "Transfer awaiting approval: $10,000.00", approved by the
    co-trustee, completed with confirmation `ABC123`: Savings $40,000.00, Brokerage
    $10,000.00, and `/activity` showing proposed, approved and completed by the right
    emails;
  * a monthly bill $6,500 due in 3 days: the reminder emailed **both** trustees;
    paying it from Savings gave $33,500.00 and moved the due date one month;
  * a PDF uploaded on the Savings page, listed there and on `/documents`, downloaded
    inline (`application/pdf`, `nosniff`, `private, no-store`); signed out, `curl`
    got `302` to `/sign-in`; a user of another trust got `404 Not found`;
  * a view-only member: accounts, transfers, bills, assets and documents render, with
    no forms and no transfer buttons.
* `AshOban.config/2` puts `{"0 * * * *", TrustManage.Finances.Bill.AshOban.Scheduler.Remind, []}`
  in the Oban crontab.
* The production image (`docker build`, 1 min 55 s) builds with the generated
  Dockerfile; `bin/migrate` migrated an empty database; the release started, said
  `JetStream stream and consumer are ready`, and answered `/health` as above.
* GitHub Actions: the generated workflow passed on `main` (12 min 47 s) and on draft
  PR `jamescarr/trust-manage#1` (10 min 14 s), with no change to the workflow.
* Not exercised: the SSO login (Dex or Google), the Fly deployment (deferred: `flyctl`
  was not logged in; so Managed Postgres behind PgBouncer, Tigris, NATS on a volume,
  the IPv6 settings and the Resend relay are untested), more than one node, and the
  Stripe pages (hidden from the navigation, still routable at `/billing`).
