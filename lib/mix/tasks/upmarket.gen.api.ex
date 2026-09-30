defmodule Mix.Tasks.Upmarket.Gen.Api do
  @shortdoc "Generates the API stack (Phoenix API-only + Ash + AshPostgres + AshJsonApi)"

  @moduledoc """
  Generates an Ash-backed JSON:API in an existing Phoenix project.

  The Ash packages are fetched and their installers (`ash.install`,
  `ash_postgres.install`, `ash_json_api.install`) are run by igniter, so this
  task must be run through `mix igniter.install`/`mix igniter.new`:

  ```sh
  mix igniter.new my_api --with phx.new \\
    --with-args="--no-html --no-assets --no-live --no-dashboard --no-mailer --no-gettext" \\
    --install upmarket_stack@path:/Users/jamescarr/projects/upmarkethq/upmarket_stack \\
    --stack api
  ```

  What it adds on top of the Ash installers: the object storage wiring,
  a demo domain + resource exposed at `/api`, and `docker-compose.yml` /
  `.env.example` (via `upmarket.gen.compose`, composed by `upmarket_stack.install`).
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _source) do
    %Igniter.Mix.Task.Info{
      group: :upmarket,
      example: "mix upmarket.gen.api",
      schema: [demo: :boolean, yes: :boolean],
      defaults: [demo: true],
      composes: ["ash.install", "ash_postgres.install", "ash_json_api.install"],
      installs: [
        {:ash, "~> 3.33"},
        {:ash_postgres, "~> 2.13"},
        {:ash_json_api, "~> 1.7"},
        {:ash_phoenix, "~> 2.3"}
      ]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    UpmarketStack.Gen.Api.apply(igniter, igniter.args.options)
  end
end
