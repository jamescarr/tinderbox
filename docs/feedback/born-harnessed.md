# Feedback: born harnessed

A project generated from `jamescarr/born-harnessed` starts with the harness in
place: every host port compose publishes is an environment variable so one
`.mise.local.toml` moves the whole stack, `bin/worktree-env` writes that file for
a checkout, `mise run check` is the gate CI runs, and `AGENTS.md` opens with a
tinderbox map instead of Phoenix's `mix precommit` line. Two worktrees of one
generated project run their services, migrations and gates at the same time.

Generated from this branch with

```bash
cd "$(mktemp -d)" && mix igniter.new tb_probe --with phx.new \
  --install tinderbox@path:$HOME/orca/workspaces/tinderbox/born-harnessed \
  --stack saas --themepack ember --yes
```

* **Duration**: 3 min 09 s (Elixir 1.20.4-otp-29, Erlang 29.1.2). Igniter
  initialized git and made the initial commit itself.
* **Sizes**: 78 tests in the untouched scaffold, 137 modules on the first compile.
* **Notices**: the usual ones (`picosat_elixir`, the removed `tinderbox` path
  dependency, the Stripe keys to fill in). No notice about a missing
  `AGENTS.md` stock line: `phx.new` 1.8.15's file has both lines the map
  rewrites.

## `AGENTS.md`

`head -20 AGENTS.md` shows the map first, then Phoenix's own guidelines:

```markdown
<!-- tinderbox:map:start -->
# TbProbe agent map

Read this block first. The framework guidelines below it are reference.

- **Gate:** `mise run check` is the definition of done and is what CI runs. `mix precommit` is not the gate.
...
## Worktrees

- Setup, once per new worktree: `sh bin/worktree-env && mise trust`
- Teardown, before removing a worktree: `mise run worktree:down`
- Checks are worktree-isolated: yes
<!-- tinderbox:map:end -->
```

* `grep -c "mix precommit" AGENTS.md` → `1` (the map's own mention). Phoenix's
  `- Use \`mix precommit\` alias …` line is rewritten to `mise run check`.
* The SaaS stack's `- **Always** manually write your own tailwind-based
  components … daisyUI …` line is gone (the stack is built on daisyUI).

## Ports and `bin/worktree-env`

`sh bin/worktree-env` in the checkout picked `23960-23971` on one run and
`23380-23391` on the next (both inside 20000–27999; the block follows the
checkout's path), printing

```
worktree-env: compose project tb-probe-tmp-fbxrhnmzi5-tb-probe, ports 23380-23391
worktree-env: PORT=23380 PGPORT=23381 SMTP_PORT=23382 MAILPIT_UI_PORT=23383 FLOCI_PORT=23384 FLOCI_GCP_PORT=23385 NATS_PORT=23386 NATS_MONITOR_PORT=23387 DEX_PORT=23388 HYDRA_PUBLIC_PORT=23389 HYDRA_ADMIN_PORT=23390 CLAMAV_PORT=23391
next: mise trust
```

`.mise.local.toml` carries the marker, `COMPOSE_PROJECT_NAME`, the twelve ports,
`AWS_ENDPOINT_URL`/`STORAGE_EMULATOR_HOST` pointing at the new Floci ports, and —
on the SaaS stack — `SSO_BASE_URL`, `SSO_REDIRECT_URI`, `OAUTH_ISSUER`,
`OAUTH_AUDIENCE`, `HYDRA_ADMIN_URL` and `DEX_CONFIG`, plus
`docker/dex/config.local.yaml` derived from `docker/dex/config.yaml` by the two
`sed` substitutions (`issuer: http://localhost:23388/dex`). Both generated files
are in `.gitignore` (`git status --short` in the fresh project shows neither).
A second run prints `worktree-env: already configured`; a `.mise.local.toml` it
did not write is refused with exit 1 unless `--force`.

That the ports reach the application is visible in the gate's own boot:

```
[debug] connecting to %{port: 23386, host: "localhost", tcp_opts: [:binary]}
```

## The gate

`[tasks.check]` is `up` (compose), then `mix format --check-formatted`,
`mix compile --warnings-as-errors`, `mix deps.unlock --check-unused`,
`mix test --warnings-as-errors`, `mix ash.setup --quiet` and
`mix run -e 'IO.puts(:boot_ok)'`. On the fresh project:

```
CHECK1 exit=0 duration=104s
Compiling 137 files (.ex)
Result: 78 passed
[check] $ mix ash.setup --quiet
[check] $ mix run -e 'IO.puts(:boot_ok)'
boot_ok
```

**`mix hex.audit` was removed from `[tasks.check]`** as this plan's fallback
allows. On the fresh project it fails on advisories no upgrade can clear:

```
cloak 1.1.4 - EEF-CVE-2026-95105 (HIGH)
assent 0.2.13 - EEF-CVE-2026-117656 (CRITICAL)
```

`cloak` 1.1.4 is its newest release, and `ash_authentication` requires
`assent ~> 0.2` (newest is 0.4.0), so neither can be fixed in the template. The
task's description says "unused dependencies" rather than naming the audit.

## Two worktrees at once

```bash
git worktree add ../tb_probe.wt2 -b wt2
(cd ../tb_probe.wt2 && sh bin/worktree-env && mise trust && mise exec -- mix deps.get)
(cd ../tb_probe && mise run check) & (cd ../tb_probe.wt2 && mise run check) & wait
```

| | main checkout | `wt2` |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `tb-probe-tmp-fbxrhnmzi5-tb-probe` | `tb-probe-tmp-fbxrhnmzi5-tb-probe-wt2` |
| `PORT` / `PGPORT` | 23380 / 23381 | 20400 / 20401 |
| `FLOCI_PORT` | 23384 | 20404 |
| `mise run check` | exit 0, `boot_ok` | exit 0, `boot_ok` |

`docker compose ls` while both gates ran listed both projects
(`tb-probe-…-tb-probe` and `tb-probe-…-tb-probe-wt2`, 8 services each); the
`fabric`, `drawdown`, `dvara` and `santati-control-plane` projects on this
machine kept running on their own ports throughout, and nothing collided. After
`mise run worktree:down` in both directories, `docker compose ls` has no
`tb-probe` project: `docker compose down -v --remove-orphans` removed the
containers, the networks and the volumes (pgdata included) in about 20 s.

## Fixed in the generator while making this run

* `mix hex.audit` dropped from `[tasks.check]` (see above).
* `docker-compose.yml`'s Dex volume assertion in `compose_test.exs` moved to the
  `${DEX_CONFIG:-./docker/dex/config.yaml}` form, which is what makes
  `config.local.yaml` mountable.
* Erlang is pinned from the running VM (`29.1.2` here), so `mise install` finds
  the toolchain already installed.

## Not exercised

* The API and worker stacks' gates (same `[tasks.check]`, but only the SaaS stack
  was generated end to end here).
* A machine where mise actually gates `.mise.toml`: `mise trust` printed "No
  untrusted config files found" here, as the README notes.
* Two worktrees of the project where the port checksum collides: the `nc -z`
  probe would move the second one on by 20 ports, but that path was not hit.
