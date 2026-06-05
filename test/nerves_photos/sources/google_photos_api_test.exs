defmodule NervesPhotos.Sources.GooglePhotosAPITest do
  use ExUnit.Case, async: false
  alias NervesPhotos.Sources.GooglePhotosAPI

  @config %{
    client_id: "CLIENT_ID",
    client_secret: "CLIENT_SECRET",
    refresh_token: "REFRESH_TOKEN",
    album_id: "ALBUM_ID"
  }

  @fake_jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>

  defp stub_token(conn) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "access_token" => "ACCESS_TOKEN",
        "expires_in" => 3600
      })
    )
  end

  describe "list_assets/1" do
    test "returns all media items across multiple pages" do
      {:ok, call_count} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(GooglePhotosAPIListTest, fn conn ->
        n = Agent.get_and_update(call_count, fn c -> {c, c + 1} end)

        cond do
          String.ends_with?(conn.request_path, "/token") ->
            stub_token(conn)

          n == 1 ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{
                "mediaItems" => [
                  %{
                    "id" => "ITEM1",
                    "baseUrl" => "https://lh3.googleusercontent.com/pw/ITEM1",
                    "mediaMetadata" => %{"creationTime" => "2024-06-01T12:00:00Z"}
                  },
                  %{
                    "id" => "ITEM2",
                    "baseUrl" => "https://lh3.googleusercontent.com/pw/ITEM2",
                    "mediaMetadata" => %{"creationTime" => "2024-06-02T12:00:00Z"}
                  }
                ],
                "nextPageToken" => "PAGE2"
              })
            )

          n == 2 ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{
                "mediaItems" => [
                  %{
                    "id" => "ITEM3",
                    "baseUrl" => "https://lh3.googleusercontent.com/pw/ITEM3",
                    "mediaMetadata" => %{"creationTime" => "2024-06-03T12:00:00Z"}
                  }
                ]
              })
            )
        end
      end)

      config = Map.put(@config, :req_options, plug: {Req.Test, GooglePhotosAPIListTest})
      assert {:ok, assets} = GooglePhotosAPI.list_assets(config)
      assert length(assets) == 3
      ids = Enum.map(assets, &elem(&1, 0))
      assert "ITEM1" in ids
      assert "ITEM3" in ids

      Agent.stop(call_count)
    end

    test "parses date from creationTime" do
      Req.Test.stub(GooglePhotosAPIMetaTest, fn conn ->
        if String.ends_with?(conn.request_path, "/token") do
          stub_token(conn)
        else
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "mediaItems" => [
                %{
                  "id" => "ITEM1",
                  "baseUrl" => "https://lh3.googleusercontent.com/pw/ITEM1",
                  "mediaMetadata" => %{"creationTime" => "2024-06-15T10:30:00Z"}
                }
              ]
            })
          )
        end
      end)

      config = Map.put(@config, :req_options, plug: {Req.Test, GooglePhotosAPIMetaTest})
      assert {:ok, [{"ITEM1", meta}]} = GooglePhotosAPI.list_assets(config)
      assert meta.date == ~D[2024-06-15]
      assert meta.location == nil
    end

    test "returns error when token refresh fails" do
      Req.Test.stub(GooglePhotosAPITokenErrTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      config =
        Map.merge(@config, %{
          req_options: [plug: {Req.Test, GooglePhotosAPITokenErrTest}, retry: false]
        })

      assert {:error, :invalid_grant} = GooglePhotosAPI.list_assets(config)
    end
  end

  describe "fetch_image/2" do
    test "fetches fresh baseUrl then returns image bytes" do
      {:ok, call_count} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(GooglePhotosAPIFetchTest, fn conn ->
        n = Agent.get_and_update(call_count, fn c -> {c, c + 1} end)

        cond do
          String.ends_with?(conn.request_path, "/token") ->
            stub_token(conn)

          String.contains?(conn.request_path, "mediaItems") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{
                "id" => "ITEM1",
                "baseUrl" => "https://lh3.googleusercontent.com/pw/ITEM1"
              })
            )

          n > 1 ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
            |> Plug.Conn.send_resp(200, @fake_jpeg)
        end
      end)

      config = Map.put(@config, :req_options, plug: {Req.Test, GooglePhotosAPIFetchTest})
      assert {:ok, @fake_jpeg} = GooglePhotosAPI.fetch_image("ITEM1", config)

      Agent.stop(call_count)
    end

    test "returns error when item lookup fails" do
      Req.Test.stub(GooglePhotosAPIFetchErrTest, fn conn ->
        if String.ends_with?(conn.request_path, "/token") do
          stub_token(conn)
        else
          Plug.Conn.send_resp(conn, 404, "not found")
        end
      end)

      config =
        Map.merge(@config, %{
          req_options: [plug: {Req.Test, GooglePhotosAPIFetchErrTest}, retry: false]
        })

      assert {:error, {:http, 404}} = GooglePhotosAPI.fetch_image("ITEM1", config)
    end
  end
end
