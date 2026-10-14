defmodule Tinderbox.Themepack do
  @moduledoc """
  The themepacks `mix tinderbox.gen.ui` can apply.

  A themepack is a light and a dark daisyUI theme (colors, radii, density), a
  pair of font stacks, and the shape of the app shell: a `:sidebar` or a
  `:topnav`. Every pack shares one component kit (`<App>Web.UI`), so switching
  packs rewrites only the themepack region of `assets/css/app.css` and the
  `<App>Web.UI` config, never a component.

  The CSS of each pack is `priv/templates/ui/themepacks/<name>.css.eex`.
  """

  @enforce_keys [:name, :shell, :label, :description]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          shell: :sidebar | :topnav,
          label: String.t(),
          description: String.t()
        }

  @packs [
    %{
      name: "ember",
      shell: :sidebar,
      label: "Ember",
      description: "Warm orange on charcoal, medium density. The tinderbox default."
    },
    %{
      name: "slate",
      shell: :sidebar,
      label: "Slate",
      description: "Neutral grays with indigo, compact: built for dense tool UIs."
    },
    %{
      name: "harbor",
      shell: :topnav,
      label: "Harbor",
      description: "Blue and white, roomy, top navigation."
    }
  ]

  @doc "Every themepack, the default first."
  @spec all() :: [t()]
  def all, do: Enum.map(@packs, &struct!(__MODULE__, &1))

  @doc "The names `--themepack` accepts."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@packs, & &1.name)

  @doc "The themepack applied when none is given and none is installed."
  @spec default() :: String.t()
  def default, do: "ember"

  @doc "The themepack called `name`; raises a `Mix.Error` naming the choices otherwise."
  @spec fetch!(String.t()) :: t()
  def fetch!(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil ->
        Mix.raise(
          "Unknown --themepack #{inspect(name)}. Must be one of: #{Enum.join(names(), ", ")}."
        )

      pack ->
        pack
    end
  end
end
