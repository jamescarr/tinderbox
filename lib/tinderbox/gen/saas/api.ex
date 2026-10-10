defmodule Tinderbox.Gen.Saas.Api do
  @moduledoc """
  Exposes the accounts domain over JSON:API at `/api`.

  `ash_json_api.install` already created `<App>Web.AshJsonApiRouter` (with an
  empty `domains:` list), the `:api` pipeline and the `/api/json` scope with the
  OpenAPI document and Swagger UI. The router pipeline of the SaaS stack
  (`ash_authentication_phoenix.install`) also loads the actor from a bearer
  token, so `GET /api/organizations` lists the signed-in user's organizations
  and is forbidden without a token.

  The routes themselves are declared on `<App>.Accounts.Organization`; this adds
  the accounts domain to the router's `domains:` and mounts the router at `/api`
  exactly as the API stack does (`Tinderbox.Gen.Api.mount_json_api/3`).
  """

  alias Tinderbox.Gen.Api

  @spec apply(Igniter.t(), Tinderbox.Gen.Saas.assigns()) :: Igniter.t()
  def apply(igniter, assigns) do
    Api.mount_json_api(
      igniter,
      Module.concat(assigns[:web], "AshJsonApiRouter"),
      assigns[:accounts]
    )
  end
end
