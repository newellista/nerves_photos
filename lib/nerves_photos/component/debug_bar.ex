defmodule NervesPhotos.Component.DebugBar do
  use Scenic.Component
  import Scenic.Primitives
  alias Scenic.Graph

  @impl Scenic.Component
  def validate(params) when is_map(params), do: {:ok, params}
  def validate(_), do: :error

  @impl Scenic.Scene
  def init(scene, %{current: current, total: total, width: width, height: height}, _opts) do
    label = "#{current}/#{total}"
    x = div(width, 2) - 40

    graph =
      Graph.build()
      |> rect({80, 28}, fill: {:color_rgba, {0, 0, 0, 160}},
           translate: {x, height - 36}, radius: 6)
      |> text(label, fill: :white, font_size: 16, translate: {x + 10, height - 16})

    {:ok, push_graph(scene, graph)}
  end
end
