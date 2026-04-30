defmodule NervesPhotos.Scene.Headless do
  use GenServer
  require Logger

  # Registers under Scene.Main so SlideTimer can send to it unchanged.
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: NervesPhotos.Scene.Main)
  end

  @impl true
  def init(_opts) do
    Logger.info("Scene.Headless started — no display output")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:slide_timer, :next_photo}, state) do
    case NervesPhotos.ImmichClient.advance() do
      {asset_id, %{date: date, location: location}} ->
        Logger.info("Headless slide: #{asset_id} — #{date}, #{location}")
      _ ->
        :ok
    end
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
