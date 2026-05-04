defmodule NervesPhotos.Component.WeatherOverlay do
  @moduledoc false
  use Scenic.Component
  import Scenic.Primitives
  alias NervesPhotos.Component.SickSun
  alias Scenic.Graph

  @impl Scenic.Component
  def validate(params) when is_map(params), do: {:ok, params}
  def validate(_), do: :error

  @impl Scenic.Scene
  def init(scene, params, _opts) do
    {:ok, push_graph(scene, build_graph(params))}
  end

  defp build_graph(%{weather: :unavailable, width: width, height: height}) do
    x = width - 200
    y = height - 78

    Graph.build()
    |> rect({184, 70}, fill: {:color_rgba, {0, 0, 0, 140}}, translate: {x, y})
    |> SickSun.add_to_graph(%{translate: {x + 8, y + 14}}, id: :sick_sun)
    |> text("No weather data",
      fill: {:color_rgba, {255, 255, 255, 180}},
      font_size: 13,
      translate: {x + 50, y + 38}
    )
  end

  defp build_graph(%{
         weather: {:ok, %{temp_f: temp, condition: condition}},
         width: width,
         height: height
       }) do
    x = width - 200
    y = height - 78
    temp_str = "#{round(temp)}°F"

    Graph.build()
    |> rect({184, 70}, fill: {:color_rgba, {0, 0, 0, 140}}, translate: {x, y})
    |> text(temp_str, fill: :white, font_size: 20, translate: {x + 12, y + 34})
    |> text(condition,
      fill: {:color_rgba, {255, 255, 255, 180}},
      font_size: 14,
      translate: {x + 12, y + 58}
    )
  end
end
