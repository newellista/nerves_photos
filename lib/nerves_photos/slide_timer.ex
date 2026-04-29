defmodule NervesPhotos.SlideTimer do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = opts[:interval_ms] || Application.get_env(:nerves_photos, :slide_interval_ms, 30_000)
    target = opts[:target] || NervesPhotos.Scene.Main
    schedule(interval)
    {:ok, %{interval: interval, target: target}}
  end

  @impl true
  def handle_info(:tick, state) do
    send(state.target, {:slide_timer, :next_photo})
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
