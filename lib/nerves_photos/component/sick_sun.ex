defmodule NervesPhotos.Component.SickSun do
  @moduledoc false
  use Scenic.Component
  import Scenic.Primitives
  alias Scenic.Graph

  @impl Scenic.Component
  def validate(params) when is_map(params), do: {:ok, params}
  def validate(_), do: :error

  @impl Scenic.Scene
  def init(scene, %{translate: {x, y}}, _opts) do
    graph =
      Graph.build()
      |> circle(18, fill: {:color, {255, 220, 50}}, translate: {x + 18, y + 18})
      |> line({{x + 9, y + 11}, {x + 13, y + 15}}, stroke: {2, :black})
      |> line({{x + 13, y + 11}, {x + 9, y + 15}}, stroke: {2, :black})
      |> line({{x + 22, y + 11}, {x + 26, y + 15}}, stroke: {2, :black})
      |> line({{x + 26, y + 11}, {x + 22, y + 15}}, stroke: {2, :black})
      |> line({{x + 11, y + 23}, {x + 25, y + 23}}, stroke: {2, :black})

    {:ok, push_graph(scene, graph)}
  end
end
