# Feedback: a family office on the themepack UI kit

`family_office` (local only, `~/projects/upmarkethq/family_office`) is a SaaS project
generated from this branch to try the UI kit on a real domain. An organization is a
family office; its **entities** (people, trusts, LLCs, foundations, partnerships)
hold **holdings** (cash, public and private equity, fixed income, real estate,
alternatives, valued by hand) and owe dated **obligations** (tax filings, capital
calls, distributions, meetings). Owners and admins manage; members are view-only.
`priv/repo/seeds.exs` creates the Vance Family Office: three users, six entities,
18 holdings worth $112.4M, and eleven obligations.

## Generation

```bash
cd ~/projects/upmarkethq
mix igniter.new family_office --with phx.new \
  --install tinderbox@path:/Users/jamescarr/orca/workspaces/tinderbox/sander \
  --stack saas --themepack harbor --yes
```

* **Duration**: 3 min 44 s. The notices included `Themepack Harbor (topnav shell)
  applied`; the scaffold passed its 13 tests.
* **Ports**: another project's compose stack held NATS, Dex and the Floci emulators,
  so Postgres and Mailpit ran from this project's compose file under another
  project name, NATS from a separate container, and `.mise.local.toml` moved the
  ports (`PGPORT=5461`, `NATS_PORT=4231`, `SMTP_PORT=1031`, `MAILPIT_UI_PORT=8031`,
  `PORT=4141`). SSO was not used.
* **`mix family_office.gen.domain FamilyOffice.Wealth --queues wealth:5`** created
  the domain and registered it, as documented.

## What was built, and with which kit parts

| Page | Kit components |
|---|---|
| `/dashboard` (rewritten as the overview) | `page_header`, `stat_grid` (net worth, entities, holdings, due in 30 days), `card` + daisyUI `progress` for allocation, `feed` of obligations by due date, `empty_state` |
| `/entities` | `data_table` with `ListState`, `row_click`, `avatar`, `badge`, a `modal` with an `AshPhoenix.Form` opened from the server (`:if={@form}` + `show`) |
| `/entities/:id` | breadcrumbs, `dropdown` (Edit, Delete), `stat_grid`, `tabs` patching `?tab=`, `data_table` without a state for holdings and obligations, edit/add modals, a confirm `modal` opened with `show_modal/1` |
| `/holdings` | `tabs` per asset class with counts, `data_table` |
| `/obligations` | `alert` for overdue items, `tabs` Upcoming/Done, `data_table` with row actions |

The pages were written against the generated README conventions (`find/4`,
`report/3`, `manager?/1`, `InheritOrganization`, `NotifyManagers`), and against
`/dev/ui` for the components. 11 tests were added (domain policies and isolation,
notifications, money formatting, the pages for a manager, a member and an
outsider); with the generated ones, 24 pass.

## Fixed in the kit from this run

* **The top navigation did not hold the app's sections.** With Overview, Entities,
  Holdings, Obligations, Inbox, Family and Admin, harbor's top bar cut the row off
  at 1440px: `nav_footer` (New organization, UI kit) sat inline beside it, and the
  header shrank to the page's content width (`max-w-5xl` on a default page).
  Now the top bar spans the window, `nav_footer` sits in a "More" menu, the user's
  name shows from `xl` up, and the small-screen menu has a separator before the
  footer links. The row fits seven entries at 1440px and scrolls by 33px at 1280px;
  the shell's doc now says the top bar suits about six entries and larger apps
  belong in the sidebar shell. The family office switched to slate with
  `mix tinderbox.gen.ui --themepack slate`, which changed only `assets/css/app.css`
  and `config/config.exs`.
* **`relative_time/1` only knew the past.** Upcoming obligations in a `feed` read
  "just now". It now says "in 6 d" / "in 3 h" for future times, and takes a `Date`
  ("today", "tomorrow", "in 6 d", "3 d ago"), so a `feed` item's `time` can be a
  due date.
* **A modal focused its close button.** It came first in the box, so `focus_first`
  landed on it. It is now last in the DOM (still top right), and focus starts in
  the first field, or on the first action of a confirm dialog.
* **`data_table`'s `:empty` slot hid search misses.** A search that matched nothing
  showed the "No entities yet" call to action. The slot now shows only when there
  are no rows at all; a search says `No results for "…"`.
* **No table for short lists.** The detail page's holdings used CoreComponents'
  `<.table>` in a `card`: different header style, zebra rows, and a
  `w-0` actions cell whose "Mark done" button spilled past the card edge.
  `data_table` now works without a `state` (no search, sort or paging) and takes
  a `title` shown beside the toolbar.
* **The generated README did not mention the kit.** It now says which components
  exist, how a list page uses `ListState`, where `/dev/ui` is, and to style with
  daisyUI's semantic colors.
* **The install notice pointed at `http://localhost:4000/dev/ui`**, wrong with
  `PORT` overridden; it now says `/dev/ui`.

The kit is copied into the project on generation and is the project's own code
afterwards, so these fixes reached `family_office` by rendering the three changed
templates over its files (`ui/components.ex`, `ui/shell.ex`, `ui/data_table.ex`);
the diff was only the fixes. A project generated before them would have to do the
same by hand.

## Still hand-written, candidates for the kit

* **Money.** `FamilyOffice.Wealth.Text.money/2` (`$1,234,567.80`, and
  `$112.4M` compact for headline stats). trust_manage wrote the same thing. A
  `format_number/2` with grouping and a compact form would cover both.
* **Enum labels and select options.** `Text.label/1` (`:public_equity` →
  "Public equity", `:llc` → "LLC") and `Text.options/1` for `<.input type="select">`.
  `status_badge/1` already humanizes; the kit could export that function.
* **Allocation bars.** A list of label, value and a `progress` bar, built inline on
  the overview. A `bar_list` component would make it one line.
* **Server-opened modals.** Opening a form modal from the server (`:if={@form}` plus
  `show`, `on_cancel={JS.push("cancel")}`) works and the tests can drive it, but the
  `modal/1` doc shows only the client-side `show_modal/1` pattern; it should show
  both.

## Rough edges hit

* **A date input posts `""`**, which beats an Ash attribute's `default`: "Add holding"
  failed with `is required` on `as_of` until the form was opened with today's date
  in its params.
* **`report/3` takes the result first.** `socket |> report(result, "…")` compiles
  and passes the arguments in the wrong order; the call has to be
  `result |> report(socket, "…")`.
* **The author of an obligation is not notified of it** (by `NotifyManagers`
  design), so the owner's dashboard showed "Nothing yet" while the co-trustee's
  inbox had twelve unread. Expected, but surprising on a one-person demo.
* **The detail page is wide on purpose** (`wide`), and the dashboard is not; with
  the topnav that used to change the header's width between pages. The header no
  longer follows the content width.

## Verified / not verified

* `mix format --check-formatted`, `mix compile --warnings-as-errors --force`, 24
  tests.
* In a browser (headless Chromium) at 1440px, 1280px, 1024px and 390px, light and
  dark, on harbor and then slate: the overview's numbers and allocation (net worth
  $113.2M after the run's additions), the entity list sorted by value, search with
  no match, a row click to the entity, adding a holding and an obligation through
  the modals (focus in the first field, Escape closes), editing the entity, the
  delete confirmation, holdings filtered per asset class, the overdue alert and
  "Mark done"; Marcus (admin) saw the obligations Eleanor added in his inbox and
  on his dashboard; Lila (member) saw every page with no New, Add, Actions or Mark
  done controls. The small-screen menu on harbor and the drawer on slate.
* Not exercised: SSO, deleting an entity (only the confirmation was opened),
  billing (left routable, out of the navigation), and the release image.
