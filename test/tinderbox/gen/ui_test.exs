defmodule Tinderbox.Gen.UiTest do
  use ExUnit.Case, async: false

  import Igniter.Test
  import Tinderbox.Test.SaasFixtures
  import Tinderbox.Test.SourceHelpers, only: [source: 2]

  alias Tinderbox.Gen.Ui

  @css "assets/css/app.css"
  @theme_plugin ~s|@plugin "daisyui/packages/bundle/daisyui-theme"|
  @layouts "lib/test_web/components/layouts.ex"

  test "the default pack replaces Phoenix's two themes with ember's" do
    igniter = Ui.apply(saas_project(), [])
    css = source(igniter, @css)
    config = source(igniter, "config/config.exs")

    assert css =~ "/* tinderbox:themepack ember"
    assert occurrences(css, @theme_plugin) == 2
    refute css =~ "daisyUI theme plugin."
    assert css =~ ~s|@plugin "daisyui/packages/bundle/daisyui" {|
    assert config =~ "shell: :sidebar"
    assert config =~ ~s|themepack: "ember"|
  end

  test "re-running with another pack switches it without duplicating anything" do
    igniter = saas_project() |> Ui.apply([]) |> apply_igniter!() |> Ui.apply(themepack: "harbor")
    css = source(igniter, @css)
    router = source(igniter, "lib/test_web/router.ex")

    assert css =~ "/* tinderbox:themepack harbor"
    refute css =~ "themepack ember"
    assert occurrences(css, @theme_plugin) == 2
    assert source(igniter, "config/config.exs") =~ "shell: :topnav"
    assert occurrences(source(igniter, "lib/test_web.ex"), "use TestWeb.UI\n") == 1
    assert occurrences(router, "UIGalleryLive") == 1
    assert index(router, ~s|scope "/dev"|) < index(router, "UIGalleryLive")
  end

  test "re-running without a pack keeps the installed one" do
    igniter = saas_project() |> Ui.apply(themepack: "slate") |> apply_igniter!() |> Ui.apply([])

    assert source(igniter, @css) =~ "/* tinderbox:themepack slate"
    assert source(igniter, "config/config.exs") =~ ~s|themepack: "slate"|
  end

  test "an unknown pack names the choices" do
    assert_raise Mix.Error, ~r/Must be one of: ember, slate, harbor/, fn ->
      Ui.apply(saas_project(), themepack: "neon")
    end
  end

  test "Phoenix's demo layout is wrapped in the app shell; a customized one is left alone" do
    assert source(Ui.apply(saas_project(), []), @layouts) =~ "<.app_shell"

    custom = """
    defmodule TestWeb.Layouts do
      use TestWeb, :html

      def app(assigns), do: ~H"<main>{render_slot(@inner_block)}</main>"
    end
    """

    igniter = Ui.apply(saas_project(files: [{@layouts, custom}]), [])

    assert source(igniter, @layouts) == custom
    assert Enum.any?(igniter.notices, &(&1 =~ "TestWeb.Layouts was customized"))
  end

  test "refuses a project without Phoenix's stylesheet" do
    project = test_project(files: Map.delete(files(), @css))

    assert_raise Mix.Error, ~r/needs Phoenix's Tailwind \+ daisyUI assets/, fn ->
      Ui.apply(project, [])
    end
  end

  defp occurrences(string, substring), do: length(String.split(string, substring)) - 1

  defp index(string, substring) do
    case :binary.match(string, substring) do
      {index, _length} -> index
      :nomatch -> flunk("expected #{inspect(substring)} in:\n#{string}")
    end
  end
end
