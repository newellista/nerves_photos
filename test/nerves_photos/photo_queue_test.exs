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

  describe "with a single source" do
    setup do
      source = %{type: "stub_good"}

      {:ok, pid} =
        start_supervised(
          {PhotoQueue,
           sources: [source], source_module_fn: fn _ -> GoodSource end, name: :pq_single}
        )

      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "current/0 returns first queued asset", %{pid: pid} do
      result = GenServer.call(pid, :current)
      assert {GoodSource, id, _config, %{date: _, location: _}} = result
      assert id in ["asset-1", "asset-2"]
    end

    test "advance/0 returns next asset", %{pid: pid} do
      {_, id1, _, _} = GenServer.call(pid, :current)
      {_, id2, _, _} = GenServer.call(pid, :advance)
      assert id1 != id2
    end

    test "queue_position/0 tracks index", %{pid: pid} do
      assert {1, 2} = GenServer.call(pid, :queue_position)
      GenServer.call(pid, :advance)
      assert {2, 2} = GenServer.call(pid, :queue_position)
    end

    test "advance/0 triggers re-fetch when last photo is reached", %{pid: pid} do
      # move to index 1
      GenServer.call(pid, :advance)
      # exhausts queue → re-fetch sent
      GenServer.call(pid, :advance)
      # wait for re-fetch to complete
      :sys.get_state(pid)
      assert {1, 2} = GenServer.call(pid, :queue_position)
    end
  end

  describe "with multiple sources" do
    setup do
      sources = [%{type: "stub_good"}, %{type: "stub_good"}]

      {:ok, pid} =
        start_supervised(
          {PhotoQueue,
           sources: sources, source_module_fn: fn _ -> GoodSource end, name: :pq_multi}
        )

      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "queue contains assets from all sources merged", %{pid: pid} do
      {_idx, total} = GenServer.call(pid, :queue_position)
      # 2 assets × 2 sources
      assert total == 4
    end
  end

  describe "partial source failure" do
    setup do
      sources = [%{type: "stub_good"}, %{type: "stub_fail"}]

      module_fn = fn
        %{type: "stub_good"} -> GoodSource
        %{type: "stub_fail"} -> FailingSource
      end

      {:ok, pid} =
        start_supervised(
          {PhotoQueue, sources: sources, source_module_fn: module_fn, name: :pq_partial}
        )

      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "shows photos from successful source", %{pid: pid} do
      {_idx, total} = GenServer.call(pid, :queue_position)
      assert total == 2
    end

    test "status is :ok when at least one source succeeded", %{pid: pid} do
      result = GenServer.call(pid, :current)
      assert {_module, _id, _config, _meta} = result
    end
  end

  describe "total source failure" do
    setup do
      sources = [%{type: "stub_fail"}]
      module_fn = fn _ -> FailingSource end

      {:ok, pid} =
        start_supervised(
          {PhotoQueue, sources: sources, source_module_fn: module_fn, name: :pq_fail}
        )

      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "current/0 returns :disconnected", %{pid: pid} do
      assert GenServer.call(pid, :current) == :disconnected
    end
  end

  describe "all sources empty" do
    setup do
      sources = [%{type: "stub_empty"}]
      module_fn = fn _ -> EmptySource end

      {:ok, pid} =
        start_supervised(
          {PhotoQueue, sources: sources, source_module_fn: module_fn, name: :pq_empty_src}
        )

      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "current/0 returns :empty", %{pid: pid} do
      assert GenServer.call(pid, :current) == :empty
    end
  end
end
