defmodule Tinderbox.Gen.Storage do
  @moduledoc """
  The object storage wiring both stacks share.

  Adds `ex_aws`/`ex_aws_s3`/`req`/`sweet_xml`, appends the runtime config that
  points S3 and SQS at Floci and GCS at floci-gcp, and creates `<App>.Storage` —
  the module that consumes that config.

  `Req` is the ExAws HTTP client (ExAws ships `ExAws.Request.Req` and declares
  both it and `hackney` as optional deps), so the generated project does not pull
  hackney in as well.
  """

  alias Tinderbox.Broker
  alias Tinderbox.Gen

  @spec apply(Igniter.t(), Keyword.t()) :: Igniter.t()
  def apply(igniter, _opts) do
    app = Igniter.Project.Application.app_name(igniter)
    app_dash = Broker.app_dash(app)
    prefix = Igniter.Project.Module.module_name_prefix(igniter)

    igniter
    |> Igniter.Project.Deps.add_dep({:ex_aws, "~> 2.7"})
    |> Igniter.Project.Deps.add_dep({:ex_aws_s3, "~> 2.5"})
    |> Igniter.Project.Deps.add_dep({:req, "~> 0.7"})
    |> Igniter.Project.Deps.add_dep({:sweet_xml, "~> 0.7"})
    |> Gen.append_to_runtime_exs(
      Gen.render_template("runtime_config.exs.eex", app: app, app_dash: app_dash),
      fn igniter ->
        Igniter.Project.Config.configures_root_key?(igniter, "runtime.exs", :ex_aws)
      end
    )
    |> Igniter.Project.Module.create_module(
      Module.concat(prefix, Storage),
      Gen.render_template("storage.ex.eex", app: app, module: prefix)
    )
  end
end
