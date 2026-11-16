# Feedback: itemizer, the file drop and integrations blocks in a real slice

`itemizer` (local only, `~/projects/upmarkethq/itemizer`, branch
`slice/charge-explanations`) explains a card charge by the purchases behind it: a
statement, an Amazon order export and receipt emails go in, and `APPLE.COM/BILL -59.97`
opens into the three App Store, iCloud and Apple TV items it paid for. It is the first
project generated with the two new opt-in blocks of the SaaS stack:

* **File drop** (`--file-drop`, `mix tinderbox.gen.file_drop`): `<App>.FileDrop` takes a
  file, checks its size, reads its type from its bytes, deduplicates it by sha256 per
  organization, stores it under `drop/<organization id>/…`, and an AshOban job scans it
  (ClamAV `clamd` over `INSTREAM`, or `none`) and hands it to a handler. `/drop`, a
  download controller that only ever sends attachments, and `upload_fixture/3`.
* **Integrations** (`--integrations`, implies the file drop; `mix tinderbox.gen.integrations`):
  a connector behaviour (files, webhooks, scheduled pulls), sources with encrypted
  credentials and a hashed bearer token, a record inbox stored once per
  `(source, type, external_id)` and handed with retries to `<App>.Integrations.Handler`,
  `POST /webhooks/integrations/<source id>` for n8n, Zapier or Make, `/integrations`.

The blocks were first written and tested as ordinary code in a throwaway project
(`tb_blocks` under `$TMPDIR/tinderbox-itemizer`), then turned into templates; the same
project was later reset to its scaffold to prove the retrofit task.

## Generation

```bash
cd ~/projects/upmarkethq
mix igniter.new itemizer --with phx.new \
  --install tinderbox@path:/Users/jamescarr/orca/workspaces/tinderbox/expense-tracking-app \
  --stack saas --integrations --yes
```

* **Duration**: 190 s wall time (the workbench without the blocks: 196 s).
  `--integrations` went through `mix igniter.new` to the installer as it is; the fallback
  (generate, then run the retrofit task) was not needed.
* **Ports**: the `itemizer` column of the plan, in two gitignored files: `.mise.local.toml`
  (`PGPORT 5630`, `SMTP_PORT 2130`, `MAILPIT_UI_PORT 8130`, `PORT 4230`, Floci `4630`/`4631`,
  NATS `4330`, Dex `5730`, Hydra `4430`/`4431`, `CLAMAV_PORT 3330`) and a
  `docker-compose.override.yml` with `ports: !override`. `docker/dex/config.yaml` was left
  alone; nobody signed in through SSO.
* **Jason and Decimal**: `mix deps.compile jason --force` ran before the first check, as
  `studio-next.md` rough edge 1 prescribes. Whether this project's dev build still needed
  it was not tested.
* **The untouched scaffold**: `mise run check` passed, 118 tests, among them the seven
  generated file drop and integrations test files. `docker-compose.yml` has one
  `clamav:` service (`profiles: ["scan"]`, `${CLAMAV_PORT:-3310}:3310`, a `clamav-data`
  volume); `.mise.toml` and `fly.toml` both set `FILE_DROP_SCANNER = "none"`.

## What was built

In tinderbox:

* `Tinderbox.Gen.Saas.FileDrop` and `Tinderbox.Gen.Saas.Integrations`, applied by
  `Tinderbox.Gen.Saas.generate/2` after `Mfa` (the vault exists) and before `Ops`, into
  the one `add_saas_resources` migration; `install/2` for the retrofit tasks, which make
  their own `add_file_drop` / `add_integrations` migration.
* 35 templates under `priv/templates/saas/file_drop/` and `…/integrations/`: 25 modules,
  7 test files, 2 fixtures and the runtime config. The `mixin
  <Accounts>.VersionIndexes` line is conditional, for projects generated before #17.
* `--file-drop` / `--integrations` on `tinderbox.install` and `tinderbox.gen.saas`;
  `--file-drop` on `tinderbox.gen.compose` and `.gen.mise`: the ClamAV service in the
  `scan` profile, the `FILE_DROP_*`/`CLAMAV_*` variables (`Tinderbox.Env`), and
  `FILE_DROP_SCANNER = "none"` in `fly.toml`, without which the release refuses to boot.
* `Edits.insert_line/4`, moved out of `Mfa` now that three generators edit the layout.
* Tests: `saas_file_drop_test.exs`, `saas_integrations_test.exs`, and additions to the
  install, env, compose and mise tests (237 tests, 27 new).

In itemizer, on top of the generated blocks:

* `concept.exs` (Itemizer, waitlist, three value propositions, no plans, domain
  `Spending`, activation `charge.explained`) and four generated resources: `Transaction`,
  `Purchase`, `PurchaseItem`, `Match`. Each got its own import action (`:import`
  upserts, `:link` for the matcher), kept out of the version history.
* `Itemizer.AI` (one callback, `extract_receipt/2`), `.Live` on ReqLLM 1.30 and Anthropic,
  `.Fake` (in `lib`, so dev can use it too).
* Parsers: `StatementCsv` (truebook's CSV reader plus `statement?/1`), `Ofx` (regular
  expressions over SGML and XML), `AmazonOrders` (the export ZIP or its CSV, one shipment
  per order and ship date, size limits before extraction), `Email` (gen_smtp's
  `mimemail`), `Merchants`.
* Connectors `BankCsv`, `BankOfx`, `AmazonOrders`, `ReceiptEmail` (file and webhook: a
  posted email becomes an `.eml` dropped on the file drop, so the model is only called
  from the drop's job), registered before the generic `webhook`.
* `Itemizer.Integrations.Handler` (records into rows), `Itemizer.Spending.Matcher`
  (equal totals, else sets of 2 to 4 purchases that add up, within -10/+2 days) and its
  Oban worker, the "What this charge was" card, an Explained column, a purchase's items.
* `priv/samples/` (the card statement, the Apple receipt, the Amazon export as CSV and
  ZIP, an OFX statement) and `priv/samples/demo.exs`.
* 161 tests: the scaffold's 118, the generated resource pages' tests, and the slice's own
  (parsers, connectors, the matcher's rule and its runs against the database, handler,
  the end-to-end `explain_charge_test.exs`, the receipt webhook, the transaction page).

### Where the code departs from the plan

1. **`allow_upload(:drop, accept: :any)`**, with the extensions passed to
   `<.live_file_input accept=…>` instead. LiveView's `accept:` raises on an extension the
   `mime` package does not know, and `.ofx`, `.qfx` and `.eml` are not in it; teaching
   `mime` means compile-time config and recompiling the `mime` dependency in every
   project. The picker still filters; `Sniff` decides.
2. **`apply(Handler, :handle, [record])`** in `Changes.Process`. Elixir 1.20's type checker
   sees that the generated handler only returns `:skip` and, under
   `--warnings-as-errors`, rejects the `:ok` and `{:error, _}` branches as unreachable
   (in a `case` and in function clauses alike).
3. **The connector's record type is `t:entry/0`**: `record/0` is a built-in type in
   Elixir 1.20 ("type record/0 is overriding a built-in type").
4. **`:request_sync` also sets `status: :active`** (and refuses a disabled source): the
   sync trigger only picks up active sources, so "Sync now" could not revive a source in
   `:error` otherwise.
5. **The Integrations nav entry goes after the end of the Files `<.nav_item>`**, not after
   the line containing `~p"/drop"`: the formatter breaks that item over three lines, and the
   line after the anchor is inside it.
6. **Events after commit**: `Integrations.ingest/2` asks the source's `:touch` for its
   notifications and sends them, with one `:integrations_updated`, once its
   `Repo.transaction` has committed; `Record`'s broadcast runs on updates only and
   `Source`'s skips `:touch`, the two actions that only run inside that transaction. The
   matcher writes a set of matches with one `Ash.bulk_create(transaction: :all)` and then
   records `charge.explained` itself, one event per charge explained (with the number of
   purchases and the confidence), instead of a `Track` change on `:link`, one per match
   row. Before, Ash logged "Missed 1 notifications" (ingest, the matcher) and "after_transaction
   hooks … ongoing transaction" (each record ingested, each touch, each matched set), and
   the page's reload could run before the rows it was told about had committed.
7. **`FileDrop.error_text/1`** (not in the plan): an upload, source or record that failed
   after its last attempt stored `inspect/1` of an `Ash.Error.Invalid`, 2 000 characters of
   struct on `/drop` and `/integrations`. It now stores the messages ("the handler failed:
   Provider response error (401): Anthropic API error: invalid x-api-key").
8. **`Email.parse/1`** turns bare line feeds into CRLFs (`mimemail` finds no headers
   otherwise, and an `.eml` saved on macOS has LFs) and decodes with
   `decode(binary, [{:allow_missing_version, true}])`, the plan's call: `decode/1` asks
   for UTF-8 conversion and calls `:iconv`, which is not a dependency
   (`UndefinedFunctionError`).
9. Smaller: `Match`'s `:link` is kept out of the version history too; the transaction page
   is titled with the description instead of the id; the transaction list sorts by
   posting date and has no external id column.

## Rough edges hit

1. **No Anthropic key.** `ANTHROPIC_API_KEY` in truebook's `.mise.local.toml` is the
   placeholder (`replace…`, 10 characters); Anthropic answered `401 invalid x-api-key` to
   it from both projects. The first demo run with `Itemizer.AI.Live` explained the two
   Amazon charges and left the Apple one unexplained, its email failed after three
   attempts. Per the plan's contingency, checks 5 to 7 ran with `config :itemizer,
   :ai_client, Itemizer.AI.Fake` in `config/dev.exs`, reverted afterwards. **The model was
   not exercised.** The placeholder line copied into itemizer's `.mise.local.toml` was
   removed afterwards (under mise it would override a real key exported in the shell); a
   comment there says where the key goes.
2. **LiveView uploads and unknown MIME types** (departure 1): any block that accepts
   files by extension meets it. *Wants*: a note in the UI kit or a helper that splits
   known and unknown extensions.
3. **The type checker and generated seams** (departure 2): every "the application edits
   this" module that ships with one trivial outcome will trip the same check in its
   callers. The events consumer escapes only because its `rescue` widens the type.
4. **Layout edits by line** (departure 5): `Edits.insert_line/4` is text-based and the
   formatter reshapes HEEx between runs. It works for the anchors used here; a fourth
   generator editing the nav will want an anchor on a whole element.
5. **Ash notifications in a hand-rolled transaction** (departure 6): easy to miss, only a
   warning, and the event is lost.
6. **gen_smtp's `mimemail`** wants CRLFs and iconv (departure 8).
7. **The CSV statement's account is the source's name**: sources a connector creates are
   named after it, so every row's account reads "Bank or card statement (CSV)". *Wants*: a
   source name chosen on the drop form, or the account read from the file name.
8. **The upload's Result column** prints the handler's summary as `key: value` pairs,
   including a `source_id` UUID. Readable enough for a first slice, not for a user.
9. **Starting and stopping ClamAV**: `docker compose --profile scan down` (the plan's
   command) stops the whole stack, not only ClamAV, which is compose's behaviour; and from a
   plain shell `docker compose --profile scan up` publishes 3310, not the `CLAMAV_PORT`
   of `.mise.local.toml` the app connects to (here it ran under `mise exec --`). The
   compose comment and the generated README now say `mise exec --` for the start and
   `docker compose stop clamav` for the stop.
10. **The archive limits trust the ZIP's declared sizes** (`file_info.size` from the
    central directory). [INFERENCE: an archive that lies about its sizes would be expanded
    in memory by `:zip.unzip/2`.] *Wants*: a streaming extraction with a byte budget.
11. **Two drops of the same bytes at the same moment**: the second insert fails on the
    `unique_content` identity and comes back as an Ash error, not `{:duplicate, _}`.
    [INFERENCE: not reproduced; the check-then-insert is not atomic.]
12. **Dependency advisory** on every `mix deps.get`: `cloak 1.1.4` (EEF-CVE-2026-95105,
    AES-CTR); the stack's vault uses AES-GCM.
13. `Organization`'s `:create` is not its primary action, so a script has to name it
    (`Ash.create!(Organization, …, action: :create)`).
14. **Transaction-hook warnings never reach the tests**: the generated `config/test.exs`
    sets `warn_on_transaction_hooks?: false` (the sandbox is one big transaction), and the
    demo's output was filtered, so the warnings of departure 6 were only seen in an
    unfiltered dev run after review pointed at them. *Wants*: a dev-mode smoke step in
    these runs that counts `[warning]` lines.

## Verified

1. **tinderbox**: `mise run check` passed (236 tests); the 237th, added last (the
   pre-activity-feed template branch), passed with its file's other nine.
2. **The blocks as code**: `mise run check` in the workbench passed, 118 tests (the
   scaffold's 78 and the seven new files' 40). `/drop` and `/integrations` were driven in a
   browser there: a CSV with no connector for it ended Failed with "No connector
   recognizes this file"; a webhook source showed its URL and token once, and a `fetch`
   with the token answered 202 `{"accepted":2,"duplicates":0}`, without it 401.
3. **Fresh generation**: the scaffold's 118 tests; `grep -c 'clamav:' docker-compose.yml`
   is 1; `FILE_DROP_SCANNER` is in `.mise.toml` and `fly.toml`.
4. **The slice**: `mise run check` in itemizer passed, 161 tests. An unfiltered demo run on
   a fresh dev database logged no "ongoing transaction" and no "Missed … notifications"
   warning (only JetStream's start-up one) and recorded three `charge.explained` events.
5. **Demo** (`mise run setup`, `mise exec -- mix run priv/samples/demo.exs`, fake model):

   ```text
   2026-10-03  APPLE.COM/BILL 866-712-7753 CA  -59.97  =>  Apple MVN2X8K4P1: Procreate Dreams; iCloud+ 2TB (Monthly); Apple TV+ (Monthly)
   2026-10-05  AMZN Mktp US*2K4TY8JD3  -65.94  =>  Amazon 112-1111111-1111111: USB-C Charging Cable, 6 ft, 2-Pack; Stainless Steel Water Bottle, 32 oz
   2026-10-07  TRADER JOE S #552  -48.12  =>  unexplained
   2026-10-09  AMAZON.COM*RT5LK2QW1  -22.59  =>  Amazon 112-2222222-2222222: Paperback: The Pragmatic Programmer
   2026-10-12  PAYMENT THANK YOU  400.00  =>  unexplained
   ```

   No failed upload. A second run reported all three files as already here, printed the
   same five lines, and only the token changed.
6. **Browser** (`mix phx.server` on 4230, headless, as `demo@itemizer.test`): `/drop`
   listed the three files as Processed; `/transactions` showed three Explained and two
   Unexplained; the Apple transaction's page listed the three items under "What this
   charge was"; `/integrations` listed three sources (receipt emails, the CSV statement,
   the Amazon export), each with 0 pending.
7. **Webhook**: without the token 401; with it and a `text` body 202
   `{"accepted":0,"duplicates":0}`; `/drop` then showed `email-9166848834c5a92a.eml` as
   Failed with "This email is not a receipt" (the fake does not know that receipt).
8. **ClamAV**: `docker compose --profile scan up -d --wait clamav` was healthy after 17 s
   on this machine; with `FILE_DROP_SCANNER=clamav` the 68-byte EICAR string as
   `eicar.csv` ended Infected, scan result `Eicar-Test-Signature`, its object
   `{:error, :not_found}` in the bucket, and a new CSV ended Processed with scan result
   `clean`.
9. **Retrofit**: the workbench reset to its first commit, the tinderbox path dependency
   added, `mix tinderbox.gen.integrations --yes` added both blocks in one
   `add_integrations` migration, the dependency removed: `mise run check` passed, 118 tests;
   `/drop` and `/integrations` rendered on 4220 for a new user.

## Not verified

The real model (no key; the `Live` client's request shape was only seen failing with a
401), a pulling connector beyond the test ones (no bank API), PDF statements (refused by
itemizer's extension list), the GCS storage backend (the tests' `objects_under/1` has a
GCS branch that never ran), files near the 25 MiB limit, the Fly.io release with
`FILE_DROP_SCANNER`, SSO, and the retrofit on a project generated before #11 or #17: a
generator test renders the templates' `version_indexes?: false` branch (no `mixin`), but
no such project was generated, migrated or tested. truebook and trust_manage were not
touched.
