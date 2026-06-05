# Google Photos API (OAuth) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `google_photos_api` source type backed by the official Google Photos Library API v1, giving access to all photos in an album (not just the ~300 embedded in the initial HTML page).

**Architecture:** New source type alongside the existing `google_photos` (HTML scraping) source. OAuth 2.0 device authorization grant (RFC 8628) for headless authentication — the settings UI shows a short code; the user visits a Google URL on their phone and enters it. Refresh token is stored in the source config. `list_assets/1` paginates the API's `mediaItems:search` endpoint until exhausted. `fetch_image/2` fetches a fresh `baseUrl` per item then fetches image bytes.

**Tech Stack:** Elixir, `Req ~> 0.5`, Google Photos Library API v1, OAuth 2.0 device flow. No new deps — Jason and Req are already present.

---

## Context

`Sources.GooglePhotos.list_assets/1` scrapes `photos.app.goo.gl` share pages. Exhaustive investigation confirmed that Google's share pages embed only ~300 photos in the initial HTML regardless of album size, that `pageToken` query params are silently ignored, and that the internal lazy-load XHR API requires full session cookies. The only reliable path to all photos is the official Photos Library API with OAuth.

The new source type is additive — the existing `google_photos` scraper is left in place. Users who want full album access configure `google_photos_api` instead.

---

## Files

- Create: `lib/nerves_photos/google_oauth.ex`
- Create: `lib/nerves_photos/sources/google_photos_api.ex`
- Modify: `lib/nerves_photos/photo_queue.ex` (add `source_module/1` clause)
- Modify: `lib/nerves_photos/settings_router.ex` (new source type, OAuth endpoints, JS, UI)
- Create: `test/nerves_photos/google_oauth_test.exs`
- Create: `test/nerves_photos/sources/google_photos_api_test.exs`

---

## Task 1: Manual Setup (no code — user must complete before implementation)

- [ ] **Step 1: Create a Google Cloud project**
  1. Go to https://console.cloud.google.com → New Project (e.g. "NervesPhotos")
  2. Enable the **Google Photos Library API** (search in API Library)

- [ ] **Step 2: Configure the OAuth consent screen**
  1. APIs & Services → OAuth consent screen → External user type
  2. App name: "NervesPhotos", your email as contact
  3. Add scope: `https://www.googleapis.com/auth/photoslibrary.readonly`
  4. Add your Google account email as a **test user**
  5. Save (no need to submit for verification — test mode supports up to 100 users)

- [ ] **Step 3: Create OAuth credentials**
  1. APIs & Services → Credentials → Create Credentials → OAuth client ID
  2. Application type: **TV and Limited Input devices** (this is the device flow type)
  3. Save the **Client ID** and **Client Secret** — you'll enter them in the photo frame settings

- [ ] **Step 4: Find your Album ID**

  Open your album in Google Photos on the web. The URL will look like:
  ```
  https://photos.google.com/u/0/album/AF1Qip...
  ```
  The `AF1Qip...` part is the Album ID. Copy it.

---

## Task 2: `GoogleOAuth` Module

**Files:**
- Create: `lib/nerves_photos/google_oauth.ex`
- Create: `test/nerves_photos/google_oauth_test.exs`

- [ ] **Step 1: Write the failing tests**

  Create `test/nerves_photos/google_oauth_test.exs`:

  ```elixir
  defmodule NervesPhotos.GoogleOAuthTest do
    use ExUnit.Case, async: false
    alias NervesPhotos.GoogleOAuth

    @client_id "test-client-id"
    @client_secret "test-client-secret"

    describe "device_authorize/2" do
      test "returns device_code and user_code on success" do
        Req.Test.stub(GoogleOAuthDeviceTest, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{
            "device_code" => "DEV_CODE",
            "user_code" => "ABCD-1234",
            "verification_url" => "https://google.com/device",
            "expires_in" => 1800,
            "interval" => 5
          }))
        end)

        opts = [req_options: [plug: {Req.Test, GoogleOAuthDeviceTest}]]
        assert {:ok, result} = GoogleOAuth.device_authorize(@client_id, opts)
        assert result.device_code == "DEV_CODE"
        assert result.user_code == "ABCD-1234"
        assert result.verification_url == "https://google.com/device"
        assert result.interval == 5
      end

      test "returns error on failure" do
        Req.Test.stub(GoogleOAuthDeviceErrTest, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_client"}))
        end)

        opts = [req_options: [plug: {Req.Test, GoogleOAuthDeviceErrTest}]]
        assert {:error, _} = GoogleOAuth.device_authorize(@client_id, opts)
      end
    end

    describe "poll_token/4" do
      test "returns {:ok, tokens} when user completes auth" do
        Req.Test.stub(GoogleOAuthPollSuccessTest, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{
            "access_token" => "ACCESS",
            "refresh_token" => "REFRESH",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          }))
        end)

        opts = [req_options: [plug: {Req.Test, GoogleOAuthPollSuccessTest}]]
        assert {:ok, tokens} = GoogleOAuth.poll_token(@client_id, @client_secret, "DEV_CODE", opts)
        assert tokens.access_token == "ACCESS"
        assert tokens.refresh_token == "REFRESH"
      end

      test "returns {:pending} when user has not yet authorized" do
        Req.Test.stub(GoogleOAuthPollPendingTest, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(428, Jason.encode!(%{"error" => "authorization_pending"}))
        end)

        opts = [req_options: [plug: {Req.Test, GoogleOAuthPollPendingTest}]]
        assert :pending = GoogleOAuth.poll_token(@client_id, @client_secret, "DEV_CODE", opts)
      end
    end

    describe "refresh_access_token/4" do
      test "returns fresh access_token on success" do
        Req.Test.stub(GoogleOAuthRefreshTest, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{
            "access_token" => "NEW_ACCESS",
            "expires_in" => 3600
          }))
        end)

        opts = [req_options: [plug: {Req.Test, GoogleOAuthRefreshTest}]]
        assert {:ok, "NEW_ACCESS"} =
          GoogleOAuth.refresh_access_token(@client_id, @client_secret, "REFRESH", opts)
      end

      test "returns error when refresh token is revoked" do
        Req.Test.stub(GoogleOAuthRefreshErrTest, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
        end)

        opts = [req_options: [plug: {Req.Test, GoogleOAuthRefreshErrTest}]]
        assert {:error, :invalid_grant} =
          GoogleOAuth.refresh_access_token(@client_id, @client_secret, "REFRESH", opts)
      end
    end
  end
  ```

- [ ] **Step 2: Run to confirm compile failure**

  ```bash
  MIX_TARGET=host mix test test/nerves_photos/google_oauth_test.exs --no-start 2>&1 | tail -5
  ```

  Expected: `** (UndefinedFunctionError)` or compile error.

- [ ] **Step 3: Implement `google_oauth.ex`**

  Create `lib/nerves_photos/google_oauth.ex`:

  ```elixir
  defmodule NervesPhotos.GoogleOAuth do
    @moduledoc false

    @device_endpoint "https://oauth2.googleapis.com/device/code"
    @token_endpoint "https://oauth2.googleapis.com/token"
    @scope "https://www.googleapis.com/auth/photoslibrary.readonly"

    def device_authorize(client_id, opts \\ []) do
      req = build_req(opts)

      case Req.post(req, url: @device_endpoint, form: [client_id: client_id, scope: @scope]) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, %{
            device_code: body["device_code"],
            user_code: body["user_code"],
            verification_url: body["verification_url"],
            expires_in: body["expires_in"],
            interval: body["interval"]
          }}

        {:ok, %{body: body}} ->
          {:error, body["error"]}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def poll_token(client_id, client_secret, device_code, opts \\ []) do
      req = build_req(opts)

      case Req.post(req,
             url: @token_endpoint,
             form: [
               client_id: client_id,
               client_secret: client_secret,
               device_code: device_code,
               grant_type: "urn:ietf:params:oauth:grant-type:device_code"
             ]
           ) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, %{access_token: body["access_token"], refresh_token: body["refresh_token"]}}

        {:ok, %{body: %{"error" => err}}} when err in ["authorization_pending", "slow_down"] ->
          :pending

        {:ok, %{body: body}} ->
          {:error, body["error"]}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def refresh_access_token(client_id, client_secret, refresh_token, opts \\ []) do
      req = build_req(opts)

      case Req.post(req,
             url: @token_endpoint,
             form: [
               client_id: client_id,
               client_secret: client_secret,
               refresh_token: refresh_token,
               grant_type: "refresh_token"
             ]
           ) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body["access_token"]}

        {:ok, %{body: %{"error" => "invalid_grant"}}} ->
          {:error, :invalid_grant}

        {:ok, %{body: body}} ->
          {:error, body["error"]}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp build_req(opts) do
      req_options = Keyword.get(opts, :req_options, [])
      Req.new(req_options)
    end
  end
  ```

- [ ] **Step 4: Run tests to confirm they pass**

  ```bash
  MIX_TARGET=host mix test test/nerves_photos/google_oauth_test.exs --no-start 2>&1
  ```

  Expected: all pass.

- [ ] **Step 5: Commit**

  ```bash
  git add lib/nerves_photos/google_oauth.ex test/nerves_photos/google_oauth_test.exs
  git commit -m "feat: add GoogleOAuth module for device flow and token refresh"
  ```

---

## Task 3: `GooglePhotosAPI` Source Module

**Files:**
- Create: `lib/nerves_photos/sources/google_photos_api.ex`
- Create: `test/nerves_photos/sources/google_photos_api_test.exs`

Config map shape:
```elixir
%{
  type: "google_photos_api",
  client_id: "...",
  client_secret: "...",
  refresh_token: "...",
  album_id: "..."
}
```

`list_assets/1` returns `{media_item_id, %{date: ~D[...], location: nil}}`. Using the `id` (not `baseUrl`) as source_id so `fetch_image/2` can always fetch a fresh `baseUrl` — the API-issued baseUrls expire after ~60 minutes.

- [ ] **Step 1: Write the failing tests**

  Create `test/nerves_photos/sources/google_photos_api_test.exs`:

  ```elixir
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
      |> Plug.Conn.send_resp(200, Jason.encode!(%{
        "access_token" => "ACCESS_TOKEN",
        "expires_in" => 3600
      }))
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
              |> Plug.Conn.send_resp(200, Jason.encode!(%{
                "mediaItems" => [
                  %{"id" => "ITEM1", "baseUrl" => "https://lh3.googleusercontent.com/pw/ITEM1",
                    "mediaMetadata" => %{"creationTime" => "2024-06-01T12:00:00Z"}},
                  %{"id" => "ITEM2", "baseUrl" => "https://lh3.googleusercontent.com/pw/ITEM2",
                    "mediaMetadata" => %{"creationTime" => "2024-06-02T12:00:00Z"}}
                ],
                "nextPageToken" => "PAGE2"
              }))

            n == 2 ->
              conn
              |> Plug.Conn.put_resp_header("content-type", "application/json")
              |> Plug.Conn.send_resp(200, Jason.encode!(%{
                "mediaItems" => [
                  %{"id" => "ITEM3", "baseUrl" => "https://lh3.googleusercontent.com/pw/ITEM3",
                    "mediaMetadata" => %{"creationTime" => "2024-06-03T12:00:00Z"}}
                ]
              }))
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
            |> Plug.Conn.send_resp(200, Jason.encode!(%{
              "mediaItems" => [
                %{"id" => "ITEM1", "baseUrl" => "https://lh3.googleusercontent.com/pw/ITEM1",
                  "mediaMetadata" => %{"creationTime" => "2024-06-15T10:30:00Z"}}
              ]
            }))
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

        config = Map.put(@config, :req_options, plug: {Req.Test, GooglePhotosAPITokenErrTest}, retry: false)
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
              # GET /v1/mediaItems/ITEM1
              conn
              |> Plug.Conn.put_resp_header("content-type", "application/json")
              |> Plug.Conn.send_resp(200, Jason.encode!(%{
                "id" => "ITEM1",
                "baseUrl" => "https://lh3.googleusercontent.com/pw/ITEM1"
              }))

            n > 1 ->
              # image fetch
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

        config = Map.put(@config, :req_options, plug: {Req.Test, GooglePhotosAPIFetchErrTest}, retry: false)
        assert {:error, {:http, 404}} = GooglePhotosAPI.fetch_image("ITEM1", config)
      end
    end
  end
  ```

- [ ] **Step 2: Run to confirm compile failure**

  ```bash
  MIX_TARGET=host mix test test/nerves_photos/sources/google_photos_api_test.exs --no-start 2>&1 | tail -5
  ```

- [ ] **Step 3: Implement `google_photos_api.ex`**

  Create `lib/nerves_photos/sources/google_photos_api.ex`:

  ```elixir
  defmodule NervesPhotos.Sources.GooglePhotosAPI do
    @moduledoc false
    @behaviour NervesPhotos.PhotoSource
    require Logger

    alias NervesPhotos.GoogleOAuth

    @api_base "https://photoslibrary.googleapis.com/v1"
    @fetch_size "=w1920-h1080"

    @impl true
    def list_assets(%{client_id: cid, client_secret: cs, refresh_token: rt, album_id: album_id} = config) do
      with {:ok, token} <- GoogleOAuth.refresh_access_token(cid, cs, rt, req_opts(config)) do
        fetch_all_items(token, album_id, nil, [], config)
      end
    end

    @impl true
    def fetch_image(media_item_id, %{client_id: cid, client_secret: cs, refresh_token: rt} = config) do
      with {:ok, token} <- GoogleOAuth.refresh_access_token(cid, cs, rt, req_opts(config)),
           {:ok, base_url} <- fetch_base_url(token, media_item_id, config) do
        req = Req.new(req_options(config))

        case Req.get(req, url: base_url <> @fetch_size) do
          {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
          {:ok, %{status: status}} -> {:error, {:http, status}}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    defp fetch_all_items(token, album_id, page_token, acc, config) do
      body = %{albumId: album_id, pageSize: 100}
      body = if page_token, do: Map.put(body, :pageToken, page_token), else: body
      req = Req.new(req_options(config))

      case Req.post(req,
             url: "#{@api_base}/mediaItems:search",
             headers: [authorization: "Bearer #{token}"],
             json: body
           ) do
        {:ok, %{status: 200, body: resp}} ->
          items = Map.get(resp, "mediaItems", [])
          all = acc ++ Enum.map(items, &to_asset/1)

          case Map.get(resp, "nextPageToken") do
            nil -> {:ok, all}
            next -> fetch_all_items(token, album_id, next, all, config)
          end

        {:ok, %{status: status}} ->
          {:error, {:http, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp fetch_base_url(token, media_item_id, config) do
      req = Req.new(req_options(config))

      case Req.get(req,
             url: "#{@api_base}/mediaItems/#{media_item_id}",
             headers: [authorization: "Bearer #{token}"]
           ) do
        {:ok, %{status: 200, body: %{"baseUrl" => base_url}}} -> {:ok, base_url}
        {:ok, %{status: status}} -> {:error, {:http, status}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp to_asset(%{"id" => id, "mediaMetadata" => %{"creationTime" => ts}}) do
      date =
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> DateTime.to_date(dt)
          _ -> nil
        end

      {id, %{date: date, location: nil}}
    end

    defp to_asset(%{"id" => id}), do: {id, %{date: nil, location: nil}}

    defp req_options(config), do: Map.get(config, :req_options, [])

    defp req_opts(config) do
      case Map.get(config, :req_options) do
        nil -> []
        opts -> [req_options: opts]
      end
    end
  end
  ```

- [ ] **Step 4: Run tests to confirm they pass**

  ```bash
  MIX_TARGET=host mix test test/nerves_photos/sources/google_photos_api_test.exs --no-start 2>&1
  ```

  Expected: all pass.

- [ ] **Step 5: Run the full suite**

  ```bash
  MIX_TARGET=host mix test --no-start 2>&1 | tail -5
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add lib/nerves_photos/sources/google_photos_api.ex \
          test/nerves_photos/sources/google_photos_api_test.exs
  git commit -m "feat: add GooglePhotosAPI source backed by Photos Library API v1"
  ```

---

## Task 4: Wire `google_photos_api` into PhotoQueue and Settings

**Files:**
- Modify: `lib/nerves_photos/photo_queue.ex`
- Modify: `lib/nerves_photos/settings_router.ex`

- [ ] **Step 1: Add `source_module/1` clause in `photo_queue.ex`**

  Find the existing `source_module/1` private function and add:

  ```elixir
  defp source_module(%{type: "google_photos_api"}), do: NervesPhotos.Sources.GooglePhotosAPI
  ```

- [ ] **Step 2: Add to `@valid_source_types` in `settings_router.ex`**

  Find `@valid_source_types` and add `"google_photos_api"`:

  ```elixir
  @valid_source_types ["immich", "google_photos", "google_photos_api"]
  ```

- [ ] **Step 3: Add OAuth state to `SettingsStore` keys**

  `SettingsStore` needs to persist the transient OAuth flow state between HTTP requests. Check the `SettingsStore` module for how new keys are added (look for the `@defaults` map or equivalent). Add `:pending_oauth` with a default of `nil`.

  If `SettingsStore` only allows predefined keys, use a module-level `Agent` for OAuth state instead:

  ```elixir
  # In lib/nerves_photos/settings_router.ex, at the top of the module:
  defmodule NervesPhotos.GoogleOAuthState do
    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def put(index, state), do: Agent.update(__MODULE__, &Map.put(&1, index, state))
    def get(index), do: Agent.get(__MODULE__, &Map.get(&1, index))
    def delete(index), do: Agent.update(__MODULE__, &Map.delete(&1, index))
  end
  ```

  Start it in the supervision tree in `application.ex` under the `:host` target (alongside `SettingsServer`), or start it lazily in the router using `start_link` wrapped in a `try/rescue` since it only needs to be started once.

- [ ] **Step 4: Add OAuth endpoints to `settings_router.ex`**

  Add these two routes (before the catch-all). Use the `GoogleOAuthState` agent from Step 3 to hold pending flow state:

  ```elixir
  post "/settings/photo_sources/:index/authorize" do
    index = parse_index(conn.path_params["index"])
    sources = SettingsStore.get(:photo_sources) || []

    with %{type: "google_photos_api", client_id: client_id} <- Enum.at(sources, index),
         {:ok, info} <- NervesPhotos.GoogleOAuth.device_authorize(client_id) do
      GoogleOAuthState.put(index, %{
        device_code: info.device_code,
        interval: info.interval
      })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{
        user_code: info.user_code,
        verification_url: info.verification_url,
        interval: info.interval
      }))
    else
      _ -> send_resp(conn, 500, ~s({"error":"failed"}))
    end
  end

  get "/settings/photo_sources/:index/oauth_status" do
    index = parse_index(conn.path_params["index"])
    sources = SettingsStore.get(:photo_sources) || []
    source = Enum.at(sources, index)
    state = GoogleOAuthState.get(index)

    result =
      case {source, state} do
        {%{type: "google_photos_api", client_id: cid, client_secret: cs},
         %{device_code: device_code}} ->
          case NervesPhotos.GoogleOAuth.poll_token(cid, cs, device_code) do
            {:ok, %{refresh_token: rt}} ->
              updated = Map.put(source, :refresh_token, rt)
              SettingsStore.put(:photo_sources, List.replace_at(sources, index, updated))
              GoogleOAuthState.delete(index)
              %{status: "authorized"}

            :pending ->
              %{status: "pending"}

            {:error, reason} ->
              GoogleOAuthState.delete(index)
              %{status: "error", error: to_string(reason)}
          end

        _ ->
          %{status: "not_started"}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(result))
  end
  ```

  **Note:** `SettingsStore.put/2` — check the actual API. It may be `SettingsStore.update/2` or `SettingsStore.put_setting/2`. Look at how the existing `POST /settings` handler updates settings and use the same pattern.

- [ ] **Step 5: Add render helpers for the new source type in `settings_router.ex`**

  In `render_sources_section/1` (or wherever source type buttons are listed), add a button for `google_photos_api`.

  Add a form renderer for add:

  ```elixir
  defp render_add_google_photos_api_form do
    """
    <div>
      <label>Client ID<input type="text" name="client_id" required></label>
      <label>Client Secret<input type="text" name="client_secret" required></label>
      <label>Album ID<input type="text" name="album_id"
        placeholder="AF1Qip... from photos.google.com/u/0/album/..." required></label>
      <p><em>Save first, then click Authorize to connect your Google account.</em></p>
    </div>
    """
  end
  ```

  Add an edit form renderer clause:

  ```elixir
  defp render_edit_form(%{type: "google_photos_api"} = source, index) do
    authorized = Map.get(source, :refresh_token) != nil
    """
    <div>
      <label>Client ID<input type="text" name="client_id"
        value="#{Plug.HTML.html_escape(to_string(source[:client_id]))}"></label>
      <label>Client Secret<input type="text" name="client_secret"
        placeholder="(leave blank to keep existing)"></label>
      <label>Album ID<input type="text" name="album_id"
        value="#{Plug.HTML.html_escape(to_string(source[:album_id]))}"></label>
      <p>Google account: #{if authorized, do: "Connected", else: "Not connected"}</p>
      <button type="button" onclick="startOAuth(#{index})">
        #{if authorized, do: "Re-authorize", else: "Authorize with Google"}
      </button>
      <div id="oauth-status-#{index}" style="display:none">
        <p>Visit: <strong><span id="oauth-url-#{index}"></span></strong></p>
        <p>Enter code: <strong><span id="oauth-code-#{index}"></span></strong></p>
        <p id="oauth-msg-#{index}">Waiting for authorization...</p>
      </div>
    </div>
    """
  end
  ```

- [ ] **Step 6: Add OAuth JS to `render_settings_js/0`**

  In `settings_router.ex`, find `render_settings_js/0` and append:

  ```javascript
  function startOAuth(index) {
    fetch('/settings/photo_sources/' + index + '/authorize', {method: 'POST'})
      .then(function(r) { return r.json(); })
      .then(function(data) {
        document.getElementById('oauth-status-' + index).style.display = 'block';
        document.getElementById('oauth-url-' + index).textContent = data.verification_url;
        document.getElementById('oauth-code-' + index).textContent = data.user_code;
        pollOAuth(index, (data.interval || 5) * 1000);
      })
      .catch(function() {
        alert('Failed to start authorization. Check client_id and try again.');
      });
  }

  function pollOAuth(index, intervalMs) {
    var timer = setInterval(function() {
      fetch('/settings/photo_sources/' + index + '/oauth_status')
        .then(function(r) { return r.json(); })
        .then(function(data) {
          if (data.status === 'authorized') {
            clearInterval(timer);
            document.getElementById('oauth-msg-' + index).textContent = 'Authorized! Reloading...';
            setTimeout(function() { location.reload(); }, 1500);
          } else if (data.status === 'error') {
            clearInterval(timer);
            document.getElementById('oauth-msg-' + index).textContent = 'Error: ' + data.error;
          }
        });
    }, intervalMs);
  }
  ```

- [ ] **Step 7: Run the full test suite**

  ```bash
  MIX_TARGET=host mix test --no-start 2>&1 | tail -10
  ```

  Expected: all tests pass.

- [ ] **Step 8: Run CI checks**

  ```bash
  MIX_TARGET=host mix ci
  ```

  Expected: all green.

- [ ] **Step 9: Commit**

  ```bash
  git add lib/nerves_photos/photo_queue.ex lib/nerves_photos/settings_router.ex
  git commit -m "feat: wire google_photos_api source into settings UI and photo queue"
  ```

---

## Task 5: Final Verification

- [ ] **Step 1: Manual test in host mode**

  ```bash
  MIX_TARGET=host mix run --no-halt
  ```

  1. Open `http://localhost:4000/settings`
  2. Add a `google_photos_api` source with your Client ID, Client Secret, and Album ID
  3. Click "Authorize with Google"
  4. Visit the verification URL on your phone, enter the code
  5. The settings page should auto-update to show "Connected"

- [ ] **Step 2: Verify full album count**

  In IEx (`MIX_TARGET=host iex -S mix`):

  ```elixir
  config = SettingsStore.get(:photo_sources) |> Enum.find(&(&1.type == "google_photos_api"))
  {:ok, assets} = NervesPhotos.Sources.GooglePhotosAPI.list_assets(config)
  length(assets)
  # Expected: ~4100 (your real album size), not ~300
  ```

- [ ] **Step 3: Copy plan to repo and commit**

  ```bash
  cp /Users/steve.newell/.claude/plans/let-s-plan-a-solution-iterative-harbor.md \
     docs/superpowers/plans/2026-06-05-google-photos-api-oauth.md
  git add docs/superpowers/plans/2026-06-05-google-photos-api-oauth.md
  git commit -m "docs: add Google Photos API OAuth implementation plan"
  ```
