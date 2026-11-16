defmodule Mix.Tasks.Tinderbox.Gen.FileDrop do
  @shortdoc "Adds the file drop to a project generated with --stack saas"

  @moduledoc """
  Adds the file drop to a project generated with `--stack saas` without it (a new
  project gets it with `--file-drop` or `--integrations`):

  * `/drop`: owners and admins drop files (CSV, OFX/QFX, PDF, ZIP, EML, TXT, up to
    25 MiB); members see and download them,
  * every file is type-checked by its bytes, deduplicated by sha256 per
    organization, stored in `<App>.Storage` under a key the server chooses,
    scanned (`FILE_DROP_SCANNER`: `none`, or `clamav` for a ClamAV daemon) and
    handed to `<App>.FileDrop.Handler` by an AshOban job,
  * a migration (`*_add_file_drop.exs`), `upload_fixture/3`, and tests.

  Run it in the project, after adding the tinderbox path dependency back (the
  install notice of `--stack saas` says how), then remove the dependency again:

  ```sh
  mix tinderbox.gen.file_drop
  mix ash.migrate
  ```

  It leaves `docker-compose.yml` and `.mise.toml` alone: every setting has a
  default in `config/runtime.exs`. It refuses a project that is not a
  `--stack saas` project, and one that has `<App>.FileDrop` already.
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _source) do
    %Igniter.Mix.Task.Info{
      group: :tinderbox,
      example: "mix tinderbox.gen.file_drop",
      schema: [yes: :boolean]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Tinderbox.Gen.Saas.FileDrop.install(igniter, igniter.args.options)
  end
end
