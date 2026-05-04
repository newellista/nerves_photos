defmodule NervesPhotos.Component.MetadataOverlay do
  @moduledoc false
  use Scenic.Component

  import Scenic.Primitives
  alias Scenic.Graph

  @impl Scenic.Component
  def validate(params) when is_map(params), do: {:ok, params}
  def validate(_), do: :error

  @impl Scenic.Scene
  def init(scene, params, _opts) do
    {:ok, push_graph(scene, build_graph(params))}
  end

  defp build_graph(%{date: nil, location: nil}), do: Graph.build()

  defp build_graph(%{date: date, location: location, height: height}) do
    lines =
      [format_date(date), location]
      |> Enum.reject(&is_nil/1)

    Graph.build()
    |> rect({400, 70}, fill: {:color_rgba, {0, 0, 0, 140}}, translate: {16, height - 78})
    |> draw_lines(lines, height)
  end

  defp draw_lines(graph, [], _height), do: graph

  defp draw_lines(graph, [line1], height) do
    text(graph, line1, fill: :white, font_size: 18, translate: {24, height - 52})
  end

  defp draw_lines(graph, [line1, line2 | _], height) do
    graph
    |> text(line1, fill: :white, font_size: 18, translate: {24, height - 56})
    |> text(line2,
      fill: {:color_rgba, {255, 255, 255, 180}},
      font_size: 15,
      translate: {24, height - 32}
    )
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Calendar.strftime(date, "%B %-d, %Y")
end
