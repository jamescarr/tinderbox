defmodule Tinderbox.Gen.SaasGeneratorsTest do
  # The `mix test.gen.*` tasks the SaaS generator writes are compiled and run against
  # the project it generated, so what is tested is the tasks, not their text. The Ash
  # domain list the tasks read is in the application env, which is global.
  use ExUnit.Case, async: false

  import Igniter.Test
  import Tinderbox.Test.SaasFixtures
  import Tinderbox.Test.SourceHelpers

  alias Mix.Tasks.Test.Gen.Concept
  alias Mix.Tasks.Test.Gen.Live
  alias Mix.Tasks.Test.Gen.Resource

  @project ~w(Test.Projects.Project name:string:required status:enum:draft,active budget:decimal
              owner:belongs_to:User)

  @concept """
  %{
    name: "Studio",
    tagline: "Projects without the spreadsheet",
    cta: :waitlist,
    plans: [%{key: "starter", name: "Starter", price: "$29/mo"}],
    resources: [
      %{
        name: "Project",
        attributes: "name:string:required status:enum:draft,active",
        nav: "Projects",
        icon: "hero-folder"
      },
      %{name: "Task", attributes: "title:string:required project:belongs_to:Project"}
    ],
    thresholds: %{within_days: 14, visitors: 100}
  }
  """

  setup_all do
    Application.put_env(:test, :ash_domains, [Test.Accounts])
    on_exit(fn -> Application.delete_env(:test, :ash_domains) end)

    generated = Tinderbox.Gen.Saas.apply(saas_project(), [])

    # The support module first: the tasks call it.
    for path <- ~w(lib/mix/test_gen.ex lib/mix/tasks/test.gen.domain.ex
                   lib/mix/tasks/test.gen.resource.ex lib/mix/tasks/test.gen.live.ex
                   lib/mix/tasks/test.gen.concept.ex) do
      Code.put_compiler_option(:ignore_module_conflict, true)
      generated |> source(path) |> Code.compile_string()
      Code.put_compiler_option(:ignore_module_conflict, false)
    end

    files =
      generated.rewrite
      |> Rewrite.sources()
      |> Map.new(&{&1.path, Rewrite.Source.get(&1, :content)})

    {:ok, files: files}
  end

  # A project holding what the SaaS generator wrote, as if it were on disk.
  defp project(files, extra \\ []), do: test_project(files: Map.merge(files, Map.new(extra)))

  # Modules, not task names: `compose_task/3` then only needs them compiled, which
  # the modules compiled in memory above are.
  defp gen(igniter, task, argv), do: Igniter.compose_task(igniter, task, argv)

  describe "mix test.gen.resource" do
    test "writes an organization-scoped resource, its domain, fixture and migration", %{
      files: files
    } do
      igniter = gen(project(files), Resource, @project)
      resource = source(igniter, "lib/test/projects/project.ex")

      for snippet <- [
            "belongs_to :organization, Test.Accounts.Organization, allow_nil?: false, public?: true",
            "reference :organization, on_delete: :delete",
            "reference :owner, on_delete: :nilify",
            "{Test.Accounts.Checks.ActorManagesOrganization, field: :organization_id}",
            "exists(organization.memberships, user_id == ^actor(:id))",
            "bypass actor_attribute_equals(:role, :admin)",
            "attribute :name, :string, allow_nil?: false, public?: true",
            "attribute :status, :atom",
            "constraints: [one_of: [:draft, :active]]",
            "default: :draft",
            "attribute :budget, :decimal, public?: true",
            ~s|change {Test.Analytics.Changes.Track, event: "project.created"}|,
            "belongs_to :owner, Test.Accounts.User, public?: true",
            "accept [:organization_id, :name, :status, :budget, :owner_id]"
          ] do
        assert_has(resource, snippet)
      end

      # A user is not organization-scoped: nothing to check.
      refute_has(resource, "SameOrganization")

      assert_has(source(igniter, "lib/test/projects.ex"), "resource Test.Projects.Project")
      assert_has(source(igniter, "config/config.exs"), "Test.Projects")

      fixtures = source(igniter, "test/support/fixtures.ex")
      assert_has(fixtures, "def project_fixture(organization, user, attrs \\\\ %{})")
      assert_has(fixtures, ~s|budget: Decimal.new("10.00")|)

      assert {"ash.codegen", ["add_projects"]} in igniter.tasks
      assert {"format", ["priv/repo/migrations/*add_projects.exs"]} in igniter.tasks
      assert igniter.issues == []
    end

    test "a belongs_to another resource of the organization is checked to be in it", %{
      files: files
    } do
      igniter =
        files
        |> project()
        |> gen(Resource, ~w(Test.Projects.Project name:string))
        |> gen(
          Resource,
          ~w(Test.Projects.Task title:string:required project:belongs_to:Project:required)
        )

      task = source(igniter, "lib/test/projects/task.ex")

      validation =
        "validate {Test.Accounts.Validations.SameOrganization, fields: [project_id: Test.Projects.Project]}"

      assert length(String.split(plain(task), plain(validation))) == 3
      assert_has(task, "require_atomic? false")
      assert_has(task, "reference :project, on_delete: :delete")

      assert_has(
        task,
        "belongs_to :project, Test.Projects.Project, allow_nil?: false, public?: true"
      )

      assert_has(
        source(igniter, "test/support/fixtures.ex"),
        "Map.put_new_lazy(:project_id, fn -> project_fixture(organization, user).id end)"
      )

      assert igniter.issues == []
    end

    test "--no-admin-bypass leaves platform admins to the other policies", %{files: files} do
      igniter = gen(project(files), Resource, @project ++ ["--no-admin-bypass"])

      refute_has(source(igniter, "lib/test/projects/project.ex"), "bypass actor_attribute_equals")
    end

    test "unique attributes are unique within the organization", %{files: files} do
      igniter =
        gen(project(files), Resource, ~w(Test.Projects.Project code:string:required:unique))

      assert_has(
        source(igniter, "lib/test/projects/project.ex"),
        "identity :unique_code, [:organization_id, :code]"
      )
    end

    test "refuses reserved names, unknown types and a module without a domain, before writing",
         %{files: files} do
      project = project(files)

      assert_raise Mix.Error, ~r/organization_id is reserved/, fn ->
        gen(project, Resource, ~w(Test.Projects.Project organization_id:uuid))
      end

      assert_raise Mix.Error, ~r/name:money: unknown type "money"/, fn ->
        gen(project, Resource, ~w(Test.Projects.Project name:money))
      end

      assert_raise Mix.Error, ~r/name is given more than once/, fn ->
        gen(project, Resource, ~w(Test.Projects.Project name:string name:text))
      end

      assert_raise Mix.Error, ~r/Test.Project has no domain/, fn ->
        gen(project, Resource, ~w(Test.Project name:string))
      end
    end

    test "refuses a resource that exists", %{files: files} do
      igniter = gen(project(files), Resource, @project)

      assert_raise Mix.Error, ~r/Test.Projects.Project already exists/, fn ->
        gen(igniter, Resource, @project)
      end
    end
  end

  describe "mix test.gen.live" do
    setup %{files: files} do
      %{igniter: gen(project(files), Live, @project ++ ["--icon", "hero-folder"])}
    end

    test "writes the list, show and form pages and their test", %{igniter: igniter} do
      for path <- ~w(lib/test/projects/project.ex
                     lib/test_web/live/projects_live.ex
                     lib/test_web/live/project_live.ex
                     lib/test_web/live/project_form_live.ex
                     test/test_web/live/projects_live_test.exs) do
        assert_creates(igniter, path)
      end

      index = source(igniter, "lib/test_web/live/projects_live.ex")
      assert_has(index, "defmodule TestWeb.ProjectsLive")
      assert_has(index, "search_fields: [:name]")
      assert_has(index, "sortable: [:name, :status, :budget, :inserted_at]")
      assert_has(index, ~s|id="new-project"|)
      assert_has(index, "display_name(project.owner)")

      form = source(igniter, "lib/test_web/live/project_form_live.ex")
      assert_has(form, "on_mount {TestWeb.LiveOrganization, :require_manager}")
      assert_has(form, ~s|id="project-form"|)
      assert_has(form, ~s|step="0.01"|)
      assert_has(form, "options={Enum.map([:draft, :active], &{humanize(&1), &1})}")
      assert_has(form, "options={@owner_options}")
      assert_has(form, ~s|prompt="Choose…"|)

      show = source(igniter, "lib/test_web/live/project_live.ex")
      assert_has(show, "format_value(@project.budget)")
      assert_has(show, ~s|put_flash(:error, "Project not found")|)

      test = source(igniter, "test/test_web/live/projects_live_test.exs")
      assert_has(test, ~s|project: %{name: "Sample name", status: "draft", budget: "10.00"}|)

      assert igniter.issues == []
    end

    test "routes the pages inside the signed-in session, new before :id", %{igniter: igniter} do
      router = source(igniter, "lib/test_web/router.ex")

      routes = [
        ~s|live "/projects", ProjectsLive|,
        ~s|live "/projects/new", ProjectFormLive, :new|,
        ~s|live "/projects/:id", ProjectLive|,
        ~s|live "/projects/:id/edit", ProjectFormLive, :edit|
      ]

      session = "ash_authentication_live_session :authenticated_routes"
      [_before, after_session] = router |> plain() |> String.split(plain(session), parts: 2)
      [inside, _rest] = String.split(after_session, " end ", parts: 2)

      for route <- routes, do: assert(inside =~ plain(route))
      assert order(router, ~s|live "/projects/new"|) < order(router, ~s|live "/projects/:id"|)
    end

    test "adds the navigation entry before the admin section", %{igniter: igniter} do
      layouts = source(igniter, "lib/test_web/components/layouts.ex")

      assert_has(layouts, ~s|icon="hero-folder"|)
      assert order(layouts, ~s|~p"/projects"|) < order(layouts, ~s|label="Platform"|)
    end

    test "running it again changes nothing", %{igniter: igniter} do
      again = gen(igniter, Live, @project ++ ["--icon", "hero-folder"])

      for path <- ~w(lib/test/projects/project.ex
                     lib/test_web/live/projects_live.ex
                     lib/test_web/live/project_live.ex
                     lib/test_web/live/project_form_live.ex
                     test/test_web/live/projects_live_test.exs
                     test/support/fixtures.ex
                     lib/test_web/router.ex
                     lib/test_web/components/layouts.ex) do
        assert source(again, path) == source(igniter, path), "#{path} changed on the second run"
      end

      layouts = source(again, "lib/test_web/components/layouts.ex")
      assert length(String.split(layouts, ~s|~p"/projects"|)) == 2
      assert_has_notice(again, &(&1 =~ "Test.Projects.Project exists, so it was left alone"))
    end

    test "--route and --nav name the path and the entry", %{files: files} do
      igniter =
        gen(
          project(files),
          Live,
          ~w(Test.Projects.LineItem label:string --route items --nav Items)
        )

      assert_has(source(igniter, "lib/test_web/router.ex"), ~s|live "/items", LineItemsLive|)

      layouts = source(igniter, "lib/test_web/components/layouts.ex")
      assert_has(layouts, ~s|~p"/items"|)
      assert_has(layouts, "Items")
      assert_has(layouts, "active={@current_page == :line_items}")
    end
  end

  describe "mix test.gen.concept" do
    test "rewrites the concept and generates its resources with one migration", %{files: files} do
      igniter = gen(project(files, [{"concept.exs", @concept}]), Concept, [])

      concept = source(igniter, "lib/test/concept.ex")
      assert_has(concept, "# generated-from: concept.exs")
      assert_has(concept, ~s|def name, do: "Studio"|)
      assert_has(concept, ~s|def tagline, do: "Projects without the spreadsheet"|)
      assert_has(concept, "def cta, do: :waitlist")
      assert_has(concept, ~s|def activation_event, do: "project.created"|)

      assert_has(
        concept,
        "within_days: 14, visitors: 100, waitlist: nil, registered: nil, activated: nil, paying: nil"
      )

      assert_has(concept, ~s|description: "", features: []|)

      for path <- ~w(lib/test/core.ex lib/test/core/project.ex lib/test/core/task.ex
                     lib/test_web/live/projects_live.ex) do
        assert_creates(igniter, path)
      end

      refute Rewrite.has_source?(igniter.rewrite, "lib/test_web/live/tasks_live.ex")

      assert_has(
        source(igniter, "lib/test/core/task.ex"),
        "fields: [project_id: Test.Core.Project]"
      )

      assert Enum.filter(igniter.tasks, &match?({"ash.codegen", _}, &1)) ==
               [{"ash.codegen", ["add_core"]}]

      assert_has_notice(igniter, &(&1 =~ "/projects its first page"))
      assert igniter.issues == []
    end

    test "reports every problem with the manifest at once", %{files: files} do
      manifest = String.replace(@concept, ~s|cta: :waitlist,|, ~s|cta: :maybe,\n  colour: 1,|)

      error =
        assert_raise Mix.Error, fn ->
          gen(project(files, [{"concept.exs", manifest}]), Concept, [])
        end

      assert error.message =~ "Unknown key colour"
      assert error.message =~ "cta must be :waitlist or :register"
    end

    test "a belongs_to has to come after its target", %{files: files} do
      manifest =
        String.replace(
          @concept,
          ~r/(%\{\s*name: "Project".*?\},)\s*(%\{name: "Task".*?\})/s,
          "\\2,\n\\1"
        )

      assert_raise Mix.Error, ~r/list Project before Task/, fn ->
        gen(project(files, [{"concept.exs", manifest}]), Concept, [])
      end
    end

    test "a concept edited by hand is left alone, with a warning", %{files: files} do
      edited =
        files["lib/test/concept.ex"] |> String.replace("# generated-from: concept.exs\n", "")

      project = project(files, [{"concept.exs", @concept}, {"lib/test/concept.ex", edited}])
      igniter = gen(project, Concept, [])

      assert source(igniter, "lib/test/concept.ex") == edited
      assert_has_warning(igniter, &(&1 =~ "was edited by hand"))
    end

    test "a missing manifest says where the starter was", %{files: files} do
      assert_raise Mix.Error, ~r/concept.exs not found/, fn ->
        gen(project(Map.delete(files, "concept.exs")), Concept, [])
      end
    end
  end
end
