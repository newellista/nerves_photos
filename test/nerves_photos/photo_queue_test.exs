defmodule NervesPhotos.PhotoQueueTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.PhotoQueue

  defmodule GoodSource do
    def list_assets(_config) do
      {:ok,
       [
         {"asset-1", %{date: ~D[2024-01-01], location: "Paris"}},
         {"asset-2", %{date: ~D[2024-02-01], location: "Rome"}}
       ]}
    end

    def fetch_image(id, _config), do: {:ok, "bytes-#{id}"}
  end

  defmodule FailingSource do
    def list_assets(_config), do: {:error, :timeout}
    def fetch_image(_id, _config), do: {:error, :timeout}
  end

  defmodule EmptySource do
    def list_assets(_config), do: {:error, :empty}
    def fetch_image(_id, _config), do: {:error, :not_found}
  end

  describe "with no sources configured" do
    setup do
      {:ok, pid} = start_supervised({PhotoQueue, sources: [], name: :pq_empty})
      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "current/0 returns :not_configured", %{pid: pid} do
      assert GenServer.call(pid, :current) == :not_configured
    end

    test "advance/0 returns :not_configured", %{pid: pid} do
      assert GenServer.call(pid, :advance) == :not_configured
    end

    test "queue_position/0 returns {0, 0}", %{pid: pid} do
      assert GenServer.call(pid, :queue_position) == {0, 0}
    end
  end
end
