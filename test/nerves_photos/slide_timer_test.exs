defmodule NervesPhotos.SlideTimerTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.SlideTimer

  test "sends :next_photo to target process after interval" do
    {:ok, _pid} = start_supervised({SlideTimer, interval_ms: 50, target: self()})
    assert_receive {:slide_timer, :next_photo}, 200
  end

  test "sends repeatedly" do
    {:ok, _pid} = start_supervised({SlideTimer, interval_ms: 50, target: self()})
    assert_receive {:slide_timer, :next_photo}, 200
    assert_receive {:slide_timer, :next_photo}, 200
  end
end
