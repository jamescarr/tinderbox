# SaaS stack: next improvements

Checklist for `/plan-loop`. Each bullet is one PR against `main`. The sections under "Bullet details" are part of the bullet: read yours in full before planning.

## Rules for every bullet

* Where things live: SaaS concerns are `lib/tinderbox/gen/saas/<concern>.ex` (`apply/2`, chained in `Tinderbox.Gen.Saas.generate/2`, `lib/tinderbox/gen/saas.ex`), their templates `priv/templates/saas/<concern>/*.eex` (EEx module bodies rendered by `Tinderbox.Gen.render_template/2`; guarded edits through `Tinderbox.Gen.Saas.Edits`). The UI kit is `priv/templates/ui/*.eex` (installed by `Tinderbox.Gen.Ui`; it must compile in a plain Phoenix project without Ash/Ecto — see the `Decimal` guard in `components.ex.eex`). The project-local generators (`mix <app>.gen.resource|live|domain|concept`) are rendered from `priv/templates/saas/gen/` (`gen_support.ex.eex` is the attribute grammar; `gen/templates/*.eex` are what they emit) and copied into the project once at generation, so changes there reach new projects only.
* Tests: Igniter rewrite tests in `test/tinderbox/gen/*_test.exs` over the fixture project `Tinderbox.Test.SaasFixtures.saas_project/1` (`test/fixtures/saas/**`), asserting with `Tinderbox.Test.SourceHelpers` (`source/2`, `assert_has/2`, `order/2`) and `Igniter.Test` (`assert_creates/2`, `apply_igniter!/1`). `test/tinderbox/gen/saas_generators_test.exs` compiles the project-local generators and runs them in memory (`gen(project(files), Resource, argv)`); every grammar/template change gets a test there. Kit tests are `priv/templates/ui/components_test.exs.eex` (a template; it runs inside generated projects, not here).
* Update `priv/templates/saas/README.md.eex` (the generated project's README, "Conventions" section) and the top-level `README.md` (SaaS stack / UI kit sections) for every user-visible addition. Do not touch `docs/feedback/*`.
* Verify, in this order, under the shared lock (`lockf -k -t 14400 LOCK sh -c '…'`, bash `timeout: 0`):
  1. `mise run check` in the worktree.
  2. A scratch generated project, for every bullet except 10:
     ```
     SCRATCH=${TMPDIR:-/tmp}/plan-loop-tinderbox/b<N>; rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"; cd "$SCRATCH"
     mise exec elixir@1.20.4-otp-29 erlang@29.1 -- mix igniter.new tb<N> --with phx.new --install tinderbox@path:<WORKTREE> --stack saas --yes
     cd tb<N>
     ```
     then write `.mise.local.toml` so host ports do not collide with other projects on this machine (5432, 1025, 8025, 4000, 4002 are taken):
     ```toml
     [env]
     PGPORT = "56<NN>"
     SMTP_PORT = "21<NN>"
     MAILPIT_UI_PORT = "81<NN>"
     PORT = "42<NN>"
     SSO_REDIRECT_URI = "http://localhost:42<NN>/auth"
     ADMIN_EMAILS = "admin@tb.test"
     ```
     with `<NN>` the two-digit bullet number (bullet 3 → `5603`, `2103`, `8103`, `4203`). Run `mise trust && mise install && mise run check`; it must pass. Then run the bullet's own scratch check (in its details). Finish with `mise run down && docker compose down -v` so the next bullet's stack can bind its ports, and leave `$SCRATCH` in place for inspection. Expect ~4 min for generation and ~2 min for the first `check`.
  3. `mise run check` in the worktree again if anything changed after step 1.
* Keep existing conventions: daisyUI semantic colors only, components documented with `@doc` + `## Examples`, every new kit component shown in `priv/templates/ui/ui_gallery_live.ex.eex`, generated modules documented with a `@moduledoc`, generated tests next to generated features.

## Checklist

- [ ] `LiveHelpers.report/3` takes the socket first, like `put_flash`
- [x] `gen.live` seeds required date and datetime fields on the new-record form
- [ ] UI kit `enum_options/2` and `gen.live` selects use it
- [ ] UI kit `bar_list` component, and the modal doc shows the server-opened pattern
- [ ] Landing pricing grid fits the number of plans
- [ ] Activity feed: versions of organization-scoped resources on `/activity`, and `gen.resource` tracks versions
- [ ] API rate limiting with Hammer in the `:api` pipeline
- [ ] `file` attribute type: upload through the generated form, download through an authorized controller (after: 2, 3)
- [ ] `secret` attribute type: encrypted at rest with AshCloak and kept off the event bus (after: 6, 8)
- [ ] Dogfood: generate `studio_next`, exercise every new feature, write `docs/feedback/studio-next.md` (after: 1, 2, 3, 4, 5, 6, 7, 8, 9)

## Bullet details

### 1. `report/3` socket first

`priv/templates/saas/web/live_helpers.ex.eex:22-29`: change to `report(socket, result, message)` — clauses `report(socket, :ok, message)`, `report(socket, {:ok, _record}, message)`, `report(socket, {:error, error}, _message)`; spec `Phoenix.LiveView.Socket.t(), :ok | {:ok, term()} | {:error, term()}, String.t()`. Reason (in the `@doc`): `socket |> report(result, "…")` reads like `put_flash` and the old order failed at runtime when piped from the socket. Update every caller to `socket |> report(result, "…") |> load()`: `priv/templates/saas/web/live/members_live.ex.eex` (lines 63, 74, 85), `priv/templates/saas/web/live/connections_live.ex.eex:74`, `priv/templates/saas/gen/templates/index_live.ex.eex:56` (its pipeline is `result |> report(socket, …) |> load() |> run(socket.assigns.table)` → `socket |> report(result, …) |> load() |> run(socket.assigns.table)`). `grep -rn "report(" priv/templates lib README.md` must then show only socket-first calls. README: `priv/templates/saas/README.md.eex:208` lists `report/3` — add "(`socket |> report(result, msg)`)". Tests: `test/tinderbox/gen/saas_test.exs` asserts on the members page source — add `assert_has(source, "report(socket, result")`; `saas_generators_test.exs` `gen.live` test asserts the index page contains `socket |> report(result`.

Scratch check: `mise exec -- mix tb01.gen.live Tb01.Core.Project name:string:required` then `mise run check` (the generated index test deletes a row through `report/3`).

### 2. Date and datetime seeding in `gen.live`

Problem: a `<input type="date">` posts `""`, which Ash reads as nil; required date/datetime fields fail on the first submit of an untouched form. In `priv/templates/saas/gen/templates/form_live.ex.eex:30-43` (`apply_action(socket, :new, _)`), the `params:` map becomes `%{"organization_id" => organization.id}` plus, for every attribute with `required?` and `input: :date`, `"<name>" => Date.to_iso8601(Date.utc_today())`, and with `input: :datetime`, `"<name>" => Calendar.strftime(DateTime.utc_now(), "%Y-%m-%dT%H:%M")`. Render it from a new assign `@seeded` built in `gen_support.ex.eex`'s `assigns/3` (next to `form_params`): a list of `{name, expression_string}` so the template stays declarative; empty list → the map is unchanged. Test in `saas_generators_test.exs`: `gen.live` on `Test.Projects.Milestone name:string:required due_on:date:required starts_at:datetime:required` asserts the form source contains `"due_on" => Date.to_iso8601(Date.utc_today())` and `"starts_at" => Calendar.strftime(DateTime.utc_now(), "%Y-%m-%dT%H:%M")`, and that `name:string:required due_on:date` (optional) seeds nothing.

Scratch check: `mix tb02.gen.live Tb02.Core.Milestone name:string:required due_on:date:required` then `mise run check`; then `mise run dev` in the background, sign up, create an organization, open `/milestones/new` and confirm the date input is prefilled with today (headless Chromium or `curl` the rendered page after sign-in via the LiveView test helper — a test in the scratch project is acceptable: `live(conn, ~p"/milestones/new")` and assert `value="#{Date.utc_today()}"`).

### 3. `enum_options/2`

Add to `priv/templates/ui/components.ex.eex` after `humanize/1` (line ~603):

```elixir
@doc """
Select options for an enum: `[{label, value}]` with `humanize/1` labels, and
`labels:` for the ones it gets wrong.

    enum_options([:draft, :llc], labels: %{llc: "LLC"})  #=> [{"Draft", :draft}, {"LLC", :llc}]
"""
@spec enum_options([atom() | String.t()], keyword()) :: [{String.t(), atom() | String.t()}]
def enum_options(values, opts \\ []) do
  labels = Keyword.get(opts, :labels, %{})
  Enum.map(values, &{Map.get(labels, &1, humanize(&1)), &1})
end
```

`priv/templates/saas/gen/templates/form_live.ex.eex:133`: `options={enum_options(<%= inspect(attribute.values) %>)}`. Kit test in `components_test.exs.eex`: `enum_options([:draft, :llc], labels: %{llc: "LLC"}) == [{"Draft", :draft}, {"LLC", :llc}]`. Generator test: the `gen.live` form for `@project` (has `status:enum:draft,active`) contains `enum_options([:draft, :active])`. README conventions line 221-229: mention `humanize`, `format_number`, `enum_options` as the kit's formatting helpers; top-level `README.md` UI kit section likewise.

Scratch check: `mix tb03.gen.live Tb03.Core.Project name:string:required status:enum:draft,active` then `mise run check`.

### 4. `bar_list`, and the modal doc

`bar_list/1` in `components.ex.eex`, placed after `feed/1` (data display group): attrs `items` (required; list of maps with `:label`, `:value` (number or Decimal), optional `:hint`), `total` (number, default: sum of values; the share is `value / total`, 0 when total is 0), `format` (`(value -> String.t())`, default `&format_number/1`), `class`. Renders each item as a row: label left, formatted value right (and `hint` muted beside it), then a daisyUI `<progress class="progress progress-primary w-full" value={share} max="100">`; `aria-label` on the progress = "label: value". Doc example: allocation by asset class. Gallery: a card "Bar list" in the `display` section of `priv/templates/ui/ui_gallery_live.ex.eex` with three items. Kit test: render through `Phoenix.LiveViewTest.render_component/2`? — no: the kit tests are plain `ExUnit.Case` without LiveView helpers; test the share math by extracting it to `bar_list_share(value, total)` (public, `@doc false`) and asserting `bar_list_share(25, 100) == 25`, `bar_list_share(1, 0) == 0`, `Decimal` input when loaded.

Modal doc (`components.ex.eex:680-699`): add a second example under "## Examples", titled "Opened from the server":

```heex
<.modal :if={@form} id="edit-holding" show on_cancel={JS.push("cancel")}>
  <:title>Edit holding</:title>
  <.form for={@form} phx-submit="save">…</.form>
</.modal>
```

with the sentence: "assign `form` to open it; `cancel` clears the assign, and `phx-remove` closes it when the assign goes." README kit list (`README.md.eex:221-224`) and top-level README gain `bar_list`.

Scratch check: `mise run check`, then `mise run dev` and load `/dev/ui` (dev only) → the "Bar list" card renders three progress bars (headless Chromium screenshot, or `curl -s localhost:42<NN>/dev/ui | grep -c '<progress'` ≥ 3).

### 5. Pricing grid

`priv/templates/saas/web/home.html.heex.eex:77`: the class list depends on `length(@concept.plans)`, with literal classes so Tailwind sees them:

```heex
<div class={[
  "mt-8 grid gap-4",
  length(@concept.plans) == 1 && "mx-auto max-w-md",
  length(@concept.plans) == 2 && "mx-auto max-w-3xl sm:grid-cols-2",
  length(@concept.plans) >= 3 && "sm:grid-cols-2 lg:grid-cols-3"
]}>
```

Same treatment for the value-prop grid at line 67 (`sm:grid-cols-3` → 1/2/3+ variants: `mx-auto max-w-md`, `mx-auto max-w-3xl sm:grid-cols-2`, `sm:grid-cols-3`). Test: `saas_test.exs` already asserts on `home.html.heex`; add `assert_has(home, "max-w-3xl sm:grid-cols-2")`. The generated `page_controller_test.exs.eex` (`priv/templates/saas/web/`) checks the default concept renders; add an assertion that the default two-plan concept's page contains `max-w-3xl`.

Scratch check: `mise run check`; `curl -s localhost:42<NN>/` after `mise run dev` contains `max-w-3xl sm:grid-cols-2` and no `lg:grid-cols-3`.

### 6. Activity feed

Two halves, one PR.

(a) `gen.resource` tracks versions. `priv/templates/saas/gen/templates/resource.ex.eex:8-13`: add `AshPaperTrail.Resource` to `extensions`, and a `paper_trail do` block identical to `priv/templates/saas/accounts/organization.ex.eex:32-38` except `create_version_on_destroy? true` and `reference_source? false` (a deleted row leaves its versions, so the feed can say "deleted"). `priv/templates/saas/gen/gen_domain_task.ex.eex` (line ~49, right after the `Igniter.compose_task(igniter, "ash.gen.domain", …)` branch; `gen.resource` and `gen.concept` both create domains through this task) adds the extension exactly as `lib/tinderbox/gen/saas/accounts.ex:254-263` does: `Spark.Igniter.add_extension(igniter, domain, Ash.Domain, :extensions, AshPaperTrail.Domain)` then `Spark.Igniter.set_option(igniter, domain, [:paper_trail, :include_versions?], true)` — on every invocation (both are idempotent), so a pre-existing domain without the extension gets it too. `saas_generators_test.exs`: the resource test asserts `AshPaperTrail.Resource` and `create_version_on_destroy? true`; the domain test asserts `AshPaperTrail.Domain` and `include_versions? true`.

Version rows carry the organization as a column. AshPaperTrail keeps source attributes only inside `changes` unless they are listed in `attributes_as_attributes`, and with `change_tracking_mode :changes_only` `organization_id` is in `changes` on create only; so `filter(organization_id == ^id)` on a version resource fails today, and filtering `changes` in memory would read every version row on each page load. Every organization-scoped `paper_trail` block gets `attributes_as_attributes [:organization_id]` and `mixin <Accounts>.VersionIndexes`: the existing blocks in `priv/templates/saas/accounts/membership.ex.eex`, `accounts/invitation.ex.eex`, `billing/subscription.ex.eex`, `connections/connection.ex.eex`, and the new `gen.resource` block (not `Organization`, whose versions are keyed by `version_source_id`). `<Accounts>.VersionIndexes` (new template `priv/templates/saas/accounts/version_indexes.ex.eex`, created by `Tinderbox.Gen.Saas.Accounts`, which runs before the concerns that use it) is a `__using__/1` macro expanding to `postgres do custom_indexes do index [:organization_id, :version_inserted_at] end end`, so the feed's per-organization, newest-first read is an index scan. If Spark rejects the mixin's `postgres` block in the version resource, say so in the PR body and ship the column without the index. Tests: `saas_test.exs` asserts `attributes_as_attributes [:organization_id]` and the `mixin` line in the four sources and `assert_creates` the mixin module; the `saas_generators_test.exs` resource test asserts both.

(b) `<Prefix>.Activity` (new template `priv/templates/saas/web/activity.ex.eex`, created from `Tinderbox.Gen.Saas.Web` next to `LiveHelpers`), public API `feed(organization, opts \\ [limit: 50]) :: [entry]` with `entry :: %{at: DateTime.t(), actor: User.t() | nil, action: atom(), resource: String.t(), label: String.t(), changes: map(), record_id: term()}`. It finds version resources by walking `Application.get_env(:<app>, :ash_domains)` → `Ash.Domain.Info.resources/1` → `AshPaperTrail.Resource.Info.version_resource/1` for resources with the extension; for each version resource whose source has an `organization_id` attribute it reads versions `filter(organization_id == ^organization.id)`; for `Organization.Version` it filters `version_source_id == ^organization.id`. Versions are read with `authorize?: false` (the LiveView's `:require_organization` hook has already established membership, and version resources carry no policies) and `load: [:user]` (the `belongs_to_actor :user` relationship). Each per-resource read is `sort(version_inserted_at: :desc) |> limit(limit)` in the query, so one request reads at most (version resources × `limit`) rows; merge those, sort by `version_inserted_at` desc, take `limit`. `label` is the source's name/title/email attribute when the version `changes` or source carries one, else the short id. `action` is `version_action_name`; `resource` is the humanized source module suffix. Skip sensitive attributes (`Ash.Resource.Info.attribute(source, key).sensitive?`) from `changes`.

`ActivityLive` (`priv/templates/saas/web/live/activity_live.ex.eex`, added to `@live_views` in `lib/tinderbox/gen/saas/web.ex:27-28` and to `live_routes/0` as `live "/activity", ActivityLive`), modeled on `dashboard_live.ex.eex`: the three `on_mount` hooks, `Layouts.app … current_page={:activity} wide`, `<.page_header>` "Activity", a `<.feed>` of entries ("`actor email` `action` `resource` `label` · `relative_time`", with a `<.description_list>` of `changes` under each) or `<.empty_state>`. Nav: `priv/templates/saas/web/layouts.ex.eex` adds `<.nav_item navigate={~p"/activity"} icon="hero-clock" active={@current_page == :activity}>Activity</.nav_item>` after Members (line ~80), before Billing. Generated test `test/<app>_web/live/activity_live_test.exs` (template `priv/templates/saas/test/activity_live_test.exs.eex`, written like `members_live_test.exs.eex`): owner creates an organization through the fixture, invites nobody; `live(conn, ~p"/activity")` lists an `organization` `create` entry and a `membership` `create` entry; a member of another organization sees "Nothing yet". Rewrite tests in `saas_test.exs`: `assert_creates` the three new files, the route inside `:authenticated_routes`, the nav entry, idempotency list unchanged.

README conventions: a bullet "Every organization-scoped resource keeps versions (AshPaperTrail) and `/activity` lists them; `<Prefix>.Activity.feed/2` is the query. Resources you write by hand get the same `paper_trail do` block as a generated one."

Scratch check: `mix tb06.gen.live Tb06.Core.Project name:string:required` → `mise run check` (the generated activity test plus the project's tests); under `mise run dev`, create a project and confirm `/activity` lists "created Project <name>" (headless Chromium, or the scratch project's own activity test extended with a project fixture); `psql` into the scratch Postgres (`PGPORT=5606`) and `\d` the membership and project version tables: both have an `organization_id` column and the `(organization_id, version_inserted_at)` index.

### 7. API rate limiting

Dependency `{:hammer, "~> 7.0"}` added in `lib/mix/tasks/tinderbox.gen.saas.ex` `adds_deps` the way `Tinderbox.Gen.Saas.Mfa.deps/0` is merged there. New module `<Prefix>.RateLimit` (template `priv/templates/saas/connections/rate_limit.ex.eex`): `use Hammer, backend: :ets`; supervised child added after `<Prefix>.Vault` with `Igniter.Project.Application.add_new_child/3` (see `Mfa.add_vault/2`, `lib/tinderbox/gen/saas/mfa.ex:135-149`). Plug `<Web>.Plugs.RateLimit` (template `priv/templates/saas/connections/rate_limit_plug.ex.eex`), appended to the `:api` pipeline after `Plugs.LoadConnection` with `Igniter.Libs.Phoenix.append_to_pipeline/4` exactly as `Tinderbox.Gen.Saas.Connections.add_plug/2` does (`lib/tinderbox/gen/saas/connections.ex:92-100`). Key: `"connection:" <> id` when `conn.assigns[:current_connection]`, else `"user:" <> id` when `current_user`, else `"ip:" <> ip` (`conn.remote_ip` formatted with `:inet.ntoa/1`). Limits from `config :<app>, <Prefix>.RateLimit, limit: …, window_ms: …` read in a new runtime block (`Gen.append_to_runtime_exs/3`, guarded by `Gen.runtime_configures?(app, [RateLimit])`): `API_RATE_LIMIT` (default `"600"`) requests per `API_RATE_WINDOW_MS` (default `"60000"`); add both to `Tinderbox.Env.saas/3` (`lib/tinderbox/env.ex:86-129`) under a "API rate limit (per node)" section so `.mise.toml` and `.env.example` list them. Allowed: `<Prefix>.RateLimit.hit(key, window_ms, limit)` → `{:allow, count}` sets `x-ratelimit-limit` and `x-ratelimit-remaining`; `{:deny, retry_after_ms}` → `retry-after` (seconds, rounded up) and a 429 in the JSON:API error shape of `load_connection_plug.ex.eex:54-72` (`status: "429", title: "Too Many Requests", detail: "Rate limit exceeded; retry after N seconds"`), halted. Test config: `config/test.exs` gets `config :<app>, <Prefix>.RateLimit, limit: 1_000, window_ms: 60_000` (edited with `Igniter.Project.Config.configure/4`). Generated test added to `priv/templates/saas/connections/api_connections_test.exs.eex`: with `Application.put_env` limit 2 for the test (and reset in `on_exit`), three `GET /api/organizations` with the same token: two 200s with `x-ratelimit-remaining` 1 then 0, then a 429 with `retry-after`. Rewrite tests in `saas_test.exs`: the pipeline order `LoadConnection` before `RateLimit` (use `order/2`), the child after `Vault`, runtime block present once after applying twice. README conventions + Configuration: the two variables, the per-node ETS counter, and "multi-node deployments switch `backend:` to Hammer's Redis backend".

Scratch check: `mise run check` (runs the generated 429 test).

### 8. `file` attribute type

Grammar (`gen_support.ex.eex`): `file` is a special form like `enum`: `ash_type :map`, `input :file`, options `[public?: true, constraints: [fields: [key: [type: :string, allow_nil?: false], filename: [type: :string, allow_nil?: false], content_type: [type: :string, allow_nil?: false], size: [type: :integer, allow_nil?: false]]]]`; `required` allowed, `unique` rejected (like `map`); not searchable/sortable; `sample_value` form → `nil` (the test uploads instead), fixture → `%{key: "fixture/#{name}.txt", filename: "#{name}.txt", content_type: "text/plain", size: 5}`. `assigns/3` adds `:files` (the file attributes).

Form (`form_live.ex.eex`): when `@files != []`, `mount` calls `allow_upload(socket, :<name>, accept: :any, max_entries: 1, max_file_size: 10_000_000)` per file attribute; the input renders `<.live_file_input upload={@uploads.<name>} />` inside a labelled field with the current filename when editing; `save` runs, before `AshPhoenix.Form.submit`, `params = Map.merge(params, consume_files(socket))` where `consume_files/1` uses `consume_uploaded_entries/3` to `<Prefix>.Storage.put("#{organization.id}/<table>/#{Ash.UUID.generate()}/#{entry.client_name}", File.read!(path))` and returns `%{"<name>" => %{"key" => key, "filename" => entry.client_name, "content_type" => entry.client_type, "size" => entry.client_size}}` for each consumed entry (nothing consumed → the key is absent, so an edit keeps the stored file). `validate` must also run with the uploads (`AshPhoenix.Form.validate` as today; uploads validate themselves).

Show/index (`show_live.ex.eex`, `index_live.ex.eex`, `LiveHelpers.format_value/1`): a file value renders as `<.link href={~p"/files/#{value["key"]}"}>filename</.link>` (new `LiveHelpers.file_link/1` component; `format_value` is unchanged).

Download: `<Web>.FileController.show/2` (template `priv/templates/saas/web/file_controller.ex.eex`, route `get "/files/*key", FileController, :show` inside the `:browser` scope that already requires a signed-in user — the one holding `OrganizationController`'s `post "/organizations/switch"` route; add it with `Edits.unless_contains`), joins `key` with `/`. Authorization is membership, not the "current" organization (a controller only has the session's `current_organization_id`, which may be unset): the key's first segment must be an organization the user belongs to — `<Accounts>.Membership |> Ash.Query.filter(user_id == ^user.id and organization_id == ^org_id) |> Ash.exists?(actor: user)` (a segment that is not a UUID → false). Anything else is 404 (`send_resp(conn, 404, "Not found")`, never 403, so foreign keys are not confirmed). On a hit, `Storage.get/1`; the key carries no metadata, so the response is `application/octet-stream` with `content-disposition: attachment; filename="<basename of key>"` and `x-content-type-options: nosniff`, except extensions `.png .jpg .jpeg .gif .webp .pdf`, sent `inline` with the matching content type. `{:error, :not_found}` → 404.

Tests: `saas_generators_test.exs` resource test with `attachment:file` asserts the attribute's `fields:` constraint, the form's `allow_upload`, `live_file_input`, `consume_uploaded_entries`; the generated `live_test.exs.eex` gains, when `@files != []`, an upload through `file_input/4` + `render_upload/2` before submit and asserts the show page links `/files/`. `saas_test.exs`: `FileController` created, route present once after two applies. Generated controller test (`priv/templates/saas/web/file_controller_test.exs.eex`): owner uploads via `Storage.put("#{org.id}/x/y.txt", "hi")` → `GET /files/#{org.id}/x/y.txt` is 200 `attachment`; a member of another organization gets 404; a missing key gets 404. README: grammar table and conventions gain `file`; the storage bullet says files live under `<organization id>/…` and are served by `FileController`.

Scratch check: `mix tb08.gen.live Tb08.Core.Document title:string:required attachment:file:required` → `mise run check` (compose runs Floci, so `Storage.put` works with `STORAGE_BACKEND=s3`); then under `mise run dev`, upload a file through `/documents/new` and download it from the show page (headless Chromium; the response is `attachment`).

### 9. `secret` attribute type

Grammar: `secret` → `ash_type :string`, options `[public?: true, sensitive?: true]`, `input :password`; `required` allowed, `unique` rejected. Resource template: when any secret exists, `extensions: [AshCloak]` is added and

```elixir
cloak do
  vault <%= inspect(@vault) %>
  attributes [<secret names>]
  decrypt_by_default []
end
```

(`@vault` = `<Prefix>.Vault`, already generated by the MFA concern; add it to `gen_support.ex.eex`'s module attributes next to `@repo`). Form: `<.input type="password" autocomplete="off">`, never prefilled; on save, blank secret params are dropped (`Map.reject(params, fn {k, v} -> k in <secret names> and v == "" end)`) so an edit keeps the stored value; on create a required secret left blank fails with the normal "is required". Show/index: a secret shows as `••••••` (`format_value` is bypassed with a literal; the calculation is never loaded). Event bus: `priv/templates/saas/events/ash_notifier.ex.eex:30-33` rejects `sensitive?` attributes from the payload (and its `@moduledoc` says so); `saas_test.exs` asserts `Enum.reject(& &1.sensitive?)` (or the exact expression chosen) in the notifier. Fixture value `"s3cr3t-#{System.unique_integer([:positive])}"`; the generated live test posts it and asserts the show page does not contain it. `saas_generators_test.exs`: `api_key:secret:required` asserts `AshCloak`, `attributes [:api_key]`, `type="password"`, the blank-drop in save. README grammar table + conventions ("`secret` attributes are encrypted with `CLOAK_KEY` through `<Prefix>.Vault`, kept off the event bus, and shown masked").

Scratch check: `mix tb09.gen.live Tb09.Core.Upstream name:string:required api_key:secret:required` → `mise run check`; then `psql` into the scratch Postgres (`PGPORT=5609`) and confirm the `upstreams` table has `encrypted_api_key` (bytea) and no `api_key` column.

### 10. Dogfood

Generate `studio_next` in `~/projects/upmarkethq/studio_next` from this worktree (`mix igniter.new studio_next --with phx.new --install tinderbox@path:<WORKTREE> --stack saas --yes`, ports in `.mise.local.toml` as in the rules, `PGPORT=5610` etc.), replace `concept.exs` with a business that uses every new type: resources `Project` (`name:string:required status:enum:draft,active,archived budget:decimal starts_on:date:required`), `Document` (`title:string:required attachment:file:required project:belongs_to:Project:required`), `Upstream` (`name:string:required api_key:secret:required`); run `gen.concept`, `mise run check`, then `mise run dev` and exercise in headless Chromium: the landing page's pricing grid, registration, a project (prefilled date, enum select), a document upload and download, an upstream (masked secret), `/activity` showing all of it, `/dev/ui` bar list, and `curl` the API past the rate limit (set `API_RATE_LIMIT=3` in `.mise.local.toml`) for a 429. Write `docs/feedback/studio-next.md` in the shape of `docs/feedback/studio-demo.md` (Generation, The concept applied, In a browser, Rough edges hit, Not exercised), recording timings, every rough edge, and which generator fix each one wants. This bullet's PR contains only that file. If something is broken, the doc records it; this bullet does not fix the generator.
