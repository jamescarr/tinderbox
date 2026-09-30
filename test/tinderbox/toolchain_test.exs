defmodule Tinderbox.ToolchainTest do
  use ExUnit.Case, async: true

  alias Tinderbox.Toolchain

  # `{elixir, otp_release, otp_version}` for releases on either side of the one this
  # package was written against.
  @releases [
    {"1.19.5", "28", "28.3.1"},
    {"1.20.4", "29", "29.1"},
    {"1.21.0", "30", "30.0"},
    {"1.22.3", "30", "30.1.2.1"}
  ]

  describe "pins/1" do
    test "pins exactly the release that is running, whichever release that is" do
      for {elixir, otp_release, otp_version} <- @releases do
        vm = %{elixir: elixir, otp_release: otp_release, otp_version: otp_version}

        assert Toolchain.pins(vm) ==
                 {:running, %{elixir: "#{elixir}-otp-#{otp_release}", erlang: otp_version}}
      end
    end

    test "pins the OTP major when the install does not record a full version" do
      vm = %{elixir: "1.21.0", otp_release: "30", otp_version: nil}

      assert Toolchain.pins(vm) == {:running, %{elixir: "1.21.0-otp-30", erlang: "30"}}
    end

    test "leaves build metadata out of a version mise has to find" do
      vm = %{elixir: "1.21.0+build.7", otp_release: "30", otp_version: "30.0"}

      assert {:running, %{elixir: "1.21.0-otp-30"}} = Toolchain.pins(vm)
    end

    test "falls back for dev and pre-release builds, which mise has no version for" do
      for elixir <- ["1.21.0-dev", "1.21.0-rc.1", "1.22.0-rc.0+build.3"] do
        vm = %{elixir: elixir, otp_release: "30", otp_version: "30.0"}

        assert {:fallback, _pins} = Toolchain.pins(vm), "#{elixir} should fall back"
      end
    end

    test "the two pins agree on the OTP major, fallback included" do
      vms =
        for({elixir, otp_release, otp_version} <- @releases) do
          %{elixir: elixir, otp_release: otp_release, otp_version: otp_version}
        end ++
          [
            %{elixir: "1.21.0", otp_release: "30", otp_version: nil},
            %{elixir: "1.21.0-dev", otp_release: "30", otp_version: nil}
          ]

      for vm <- vms do
        {_source, %{elixir: elixir, erlang: erlang}} = Toolchain.pins(vm)
        [_version, elixir_otp] = String.split(elixir, "-otp-")

        assert erlang |> String.split(".") |> hd() == elixir_otp,
               "#{inspect(vm)}: Elixir #{elixir} vs Erlang #{erlang}"
      end
    end
  end

  describe "parse_otp_version/2" do
    test "accepts the dotted version of the running major" do
      assert Toolchain.parse_otp_version("29.1\n", "29") == "29.1"
      assert Toolchain.parse_otp_version("27.3.4.1", "27") == "27.3.4.1"
      assert Toolchain.parse_otp_version("29", "29") == "29"
    end

    test "rejects what mise cannot install or what belongs to another major" do
      for {contents, otp_release} <- [
            # a release candidate
            {"29.0-rc1", "29"},
            # another major, and a longer number that merely starts with this one
            {"28.3", "29"},
            {"290.1", "29"},
            {"", "29"},
            {"not a version", "29"},
            {"29.x", "29"}
          ] do
        assert Toolchain.parse_otp_version(contents, otp_release) == nil,
               "#{inspect(contents)} for OTP #{otp_release} should be rejected"
      end
    end
  end

  describe "detect/0" do
    test "reads the running VM" do
      vm = Toolchain.detect()

      assert vm.elixir == System.version()
      assert vm.otp_release == System.otp_release()

      # The full version, when the install records one, is for the running major.
      assert vm.otp_version == nil or String.starts_with?(vm.otp_version, vm.otp_release)
    end
  end
end
