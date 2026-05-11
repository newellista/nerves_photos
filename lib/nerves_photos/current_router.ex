defmodule NervesPhotos.CurrentRouter do
  @moduledoc false
  use Plug.Router
  import Plug.Conn

  plug(:match)
  plug(:dispatch)

  get "/photo" do
    case safe_call(NervesPhotos.PhotoQueue, :current, nil) do
      {module, source_id, config, _meta} ->
        case module.fetch_image(source_id, config) do
          {:ok, body} when is_binary(body) ->
            conn
            |> put_resp_header("content-type", "image/jpeg")
            |> send_resp(200, body)

          _ ->
            send_resp(conn, 503, "photo fetch failed")
        end

      _ ->
        send_resp(conn, 503, "no photo available")
    end
  end

  get "/" do
    interval_ms = NervesPhotos.SettingsStore.get(:slide_interval_ms) || 30_000
    show_debug = Application.get_env(:nerves_photos, :show_debug, false)

    weather = safe_call(NervesPhotos.WeatherFetcher, :current, :unavailable)
    photo_current = safe_call(NervesPhotos.PhotoQueue, :current, :loading)
    {current_pos, total} = safe_call(NervesPhotos.PhotoQueue, :queue_position, {0, 0})

    {has_photo, metadata, scene_status} =
      case photo_current do
        {_module, _id, _config, meta} -> {true, meta, :ok}
        status -> {false, %{date: nil, location: nil}, status}
      end

    send_resp(
      conn,
      200,
      render_current(%{
        has_photo: has_photo,
        metadata: metadata,
        scene_status: scene_status,
        weather: weather,
        interval_ms: interval_ms,
        show_debug: show_debug,
        current_pos: current_pos,
        total: total
      })
    )
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp render_current(%{
         has_photo: has_photo,
         metadata: metadata,
         scene_status: scene_status,
         weather: weather,
         interval_ms: interval_ms,
         show_debug: show_debug,
         current_pos: current_pos,
         total: total
       }) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>NervesPhotos &mdash; Current</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { background: black; width: 100vw; height: 100vh; overflow: hidden; }
        #scene { position: relative; width: 100%; height: 100%; }
        #photo { position: absolute; width: 100%; height: 100%; object-fit: contain; }
        .overlay { position: absolute; }
        #metadata {
          bottom: 8px; left: 16px;
          width: 400px; height: 70px;
          background: rgba(0,0,0,0.55); padding: 12px 8px;
        }
        .meta-date { color: white; font-size: 18px; font-family: sans-serif; }
        .meta-location { color: rgba(255,255,255,0.71); font-size: 15px;
                         font-family: sans-serif; margin-top: 2px; }
        #weather {
          bottom: 8px; right: 16px;
          width: 184px; height: 70px;
          background: rgba(0,0,0,0.55); padding: 12px;
        }
        .weather-temp { color: white; font-size: 20px; font-family: sans-serif; }
        .weather-cond { color: rgba(255,255,255,0.71); font-size: 14px;
                        font-family: sans-serif; margin-top: 4px; }
        #reconnecting {
          top: 16px; left: 50%; transform: translateX(-50%);
          background: rgba(0,0,0,0.63); color: rgb(255,204,68);
          font-size: 16px; font-family: sans-serif;
          padding: 7px 16px; border-radius: 15px; white-space: nowrap;
        }
        .centered-msg {
          top: 50%; left: 50%; transform: translate(-50%,-50%);
          background: rgba(0,0,0,0.63); color: white;
          font-size: 16px; font-family: sans-serif;
          padding: 9px 16px; border-radius: 8px; white-space: nowrap;
        }
        #debug {
          bottom: 8px; left: 50%; transform: translateX(-50%);
          width: 80px; height: 28px;
          background: rgba(0,0,0,0.63); color: white;
          font-size: 16px; font-family: sans-serif;
          border-radius: 6px; display: flex; align-items: center; justify-content: center;
        }
      </style>
      <script>setTimeout(() => location.reload(), #{interval_ms})</script>
    </head>
    <body>
    <div id="scene">
      #{if has_photo, do: ~s(<img id="photo" src="/current/photo" alt="">), else: ""}
      #{render_metadata_overlay(metadata)}
      #{render_weather_overlay(weather)}
      #{render_scene_status(scene_status)}
      #{if show_debug, do: ~s(<div id="debug" class="overlay">#{current_pos}/#{total}</div>), else: ""}
    </div>
    </body>
    </html>
    """
  end

  defp render_metadata_overlay(meta) do
    date_html =
      if meta[:date],
        do: ~s(<div class="meta-date">#{format_photo_date(meta[:date])}</div>),
        else: ""

    loc_html =
      if meta[:location],
        do: ~s(<div class="meta-location">#{Plug.HTML.html_escape(meta[:location])}</div>),
        else: ""

    if date_html == "" and loc_html == "" do
      ""
    else
      ~s(<div id="metadata" class="overlay">#{date_html}#{loc_html}</div>)
    end
  end

  defp render_weather_overlay(:unavailable) do
    ~s(<div id="weather" class="overlay"><div class="weather-cond">No weather data</div></div>)
  end

  defp render_weather_overlay({:ok, %{temp_f: temp, condition: condition}}) do
    ~s(<div id="weather" class="overlay"><div class="weather-temp">#{round(temp)}°F</div><div class="weather-cond">#{Plug.HTML.html_escape(condition)}</div></div>)
  end

  defp render_scene_status(:ok), do: ""

  defp render_scene_status(:disconnected) do
    ~s(<div id="reconnecting" class="overlay">Reconnecting...</div>)
  end

  defp render_scene_status(:loading) do
    ~s(<div class="centered-msg overlay">Loading...</div>)
  end

  defp render_scene_status(:empty) do
    ~s(<div class="centered-msg overlay">No photos found in album</div>)
  end

  defp render_scene_status(:not_configured) do
    ~s(<div class="centered-msg overlay">Not configured</div>)
  end

  defp format_photo_date(date), do: Calendar.strftime(date, "%B %-d, %Y")

  defp safe_call(name, msg, default) do
    case Process.whereis(name) do
      nil ->
        default

      pid ->
        try do
          GenServer.call(pid, msg, 2_000)
        catch
          :exit, _ -> default
        end
    end
  end
end
