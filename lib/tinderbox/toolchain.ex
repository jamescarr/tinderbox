defmodule Tinderbox.Toolchain do
  @moduledoc """
  The tools a generated project pins in `.mise.toml`.

  Elixir and Erlang are pinned to the toolchain that is running the generator.
  `mix new` records that Elixir's major.minor as the project's `elixir:`
  requirement (`~> 1.20`), and the project's dependencies are resolved and
  compiled with it, so this is the toolchain the project is known to work with. A
  constant would only be right for whoever happens to run the release it names:
  generate on a newer Elixir and `mise run dev` fails Mix's version check.

  A dev or pre-release Elixir build has no matching mise version, so `pins/1`
  falls back to the pair this package was last verified with (and
  `Tinderbox.Gen.Mise` says so).
  """

  # The toolchain the generated projects were last verified against end to end.
  # Only used when the running VM cannot be pinned; update it when re-verifying.
  @fallback %{elixir: "1.20.4-otp-29", erlang: "29.1"}

  # brod's crc32cer NIF needs CMake >= 3.16 to build; this is what ankusa pins for
  # the same dependency.
  @cmake "4.4.3"

  @typedoc "What the running Erlang VM says about itself."
  @type vm :: %{
          elixir: String.t(),
          otp_release: String.t(),
          otp_version: String.t() | nil
        }

  @type pins :: %{elixir: String.t(), erlang: String.t()}

  @doc "The CMake version pinned for the Kafka worker."
  @spec cmake() :: String.t()
  def cmake, do: @cmake

  @doc "Reads the Elixir and OTP versions of the running VM."
  @spec detect() :: vm()
  def detect do
    otp_release = System.otp_release()

    %{
      elixir: System.version(),
      otp_release: otp_release,
      otp_version: read_otp_version(otp_release)
    }
  end

  @doc """
  The `[tools]` pins for `vm`, tagged with where they came from.

  * `{:running, pins}` — Elixir is a release, so both tools are pinned to exactly
    what is running: `"1.20.4-otp-29"` and the full OTP version (`"29.1"`), or just
    the OTP major when the install does not record a full version.
  * `{:fallback, pins}` — Elixir is a dev or pre-release build.

  Either way the two pins agree on the OTP major, which is what mise's Elixir
  build (`<version>-otp-<major>`) needs to find its Erlang.
  """
  @spec pins(vm()) :: {:running | :fallback, pins()}
  def pins(%{elixir: elixir, otp_release: otp_release} = vm) do
    case Version.parse(elixir) do
      {:ok, %Version{major: major, minor: minor, patch: patch, pre: []}} ->
        {:running,
         %{
           elixir: "#{major}.#{minor}.#{patch}-otp-#{otp_release}",
           erlang: Map.get(vm, :otp_version) || otp_release
         }}

      _dev_or_pre_release ->
        {:fallback, @fallback}
    end
  end

  @doc false
  # `releases/<major>/OTP_VERSION` holds the full version ("29.1"). It is trusted
  # only when it is a plain dotted number for the running major: anything else
  # (a release candidate, a stray file) would put a version in `.mise.toml` that
  # mise cannot install.
  @spec parse_otp_version(String.t(), String.t()) :: String.t() | nil
  def parse_otp_version(contents, otp_release) do
    version = String.trim(contents)

    if String.match?(version, ~r/\A\d+(\.\d+)*\z/) and
         (version == otp_release or String.starts_with?(version, otp_release <> ".")) do
      version
    end
  end

  defp read_otp_version(otp_release) do
    path = Path.join([to_string(:code.root_dir()), "releases", otp_release, "OTP_VERSION"])

    case File.read(path) do
      {:ok, contents} -> parse_otp_version(contents, otp_release)
      {:error, _reason} -> nil
    end
  end
end
